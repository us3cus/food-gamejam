import net from 'node:net';
import { randomBytes, randomInt, randomUUID } from 'node:crypto';

const PROTOCOL_VERSION = 1;
const MAX_PACKET_BYTES = 1_048_576;
const RATE_LIMIT_PER_SECOND = 60;
const LOBBY_CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

function clampInteger(value, fallback, min, max) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(min, Math.min(max, Math.trunc(parsed)));
}

function normalizeName(value) {
  const name = String(value ?? '').trim().replace(/[\u0000-\u001f\u007f]/g, '').slice(0, 24);
  return name || 'Игрок';
}

function normalizeCode(value) {
  return String(value ?? '').trim().toUpperCase();
}

function normalizeSettings(value = {}) {
  return {
    max_players: clampInteger(value.max_players, 2, 2, 4),
    round_time: clampInteger(value.round_time, 90, 30, 180),
    wins_to_match: clampInteger(value.wins_to_match, 2, 1, 5),
    arena: 'kitchen',
  };
}

function createLobbyCode(lobbies) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const bytes = randomBytes(6);
    let code = '';
    for (const byte of bytes) code += LOBBY_CODE_ALPHABET[byte % LOBBY_CODE_ALPHABET.length];
    if (!lobbies.has(code)) return code;
  }
  throw new Error('Unable to allocate lobby code');
}

function writePacket(socket, type, payload = {}, requestId = null) {
  if (!socket.destroyed && socket.writable) {
    socket.write(`${JSON.stringify({ type, request_id: requestId, payload })}\n`);
  }
}

export function createLobbyServer({ logger = console, debug = false } = {}) {
  const lobbies = new Map();

  function debugLog(message) {
    if (debug) logger.info?.(`[tcp-debug] ${message}`);
  }

  function publicPlayers(lobby) {
    return [...lobby.players.values()].map((player) => ({
      id: player.id,
      name: player.name,
      is_host: player.id === lobby.hostId,
      ready: player.id === lobby.hostId || player.ready,
    }));
  }

  function canStart(lobby) {
    if (lobby.started || lobby.players.size < 2) return false;
    return [...lobby.players.values()].every(
      (player) => player.id === lobby.hostId || player.ready,
    );
  }

  function statusMessage(lobby) {
    if (lobby.started) return 'Матч уже запущен';
    if (lobby.players.size < 2) return 'Нужен минимум ещё один игрок';
    if (!canStart(lobby)) return 'Не все игроки готовы';
    return 'Все готовы — можно начинать';
  }

  function snapshot(lobby) {
    return {
      lobby_id: lobby.id,
      host_id: lobby.hostId,
      settings: { ...lobby.settings },
      players: publicPlayers(lobby),
      can_start: canStart(lobby),
      status_message: statusMessage(lobby),
    };
  }

  function broadcast(lobby, type, payload, exceptSocket = null) {
    for (const player of lobby.players.values()) {
      if (player.socket !== exceptSocket) writePacket(player.socket, type, payload);
    }
  }

  function broadcastLobby(lobby) {
    broadcast(lobby, 'lobby.updated', snapshot(lobby));
  }

  function sendError(player, requestId, code, message) {
    debugLog(`${player.id.slice(0, 8)} -> error ${code}`);
    writePacket(player.socket, 'error', { code, message }, requestId);
  }

  function getPlayerLobby(player, requestedId, requestId) {
    const code = normalizeCode(requestedId || player.lobbyId);
    const lobby = lobbies.get(code);
    if (!lobby || player.lobbyId !== lobby.id || !lobby.players.has(player.id)) {
      sendError(player, requestId, 'NOT_IN_LOBBY', 'Игрок не состоит в этом лобби');
      return null;
    }
    return lobby;
  }

  function leaveLobby(player, { notify = false } = {}) {
    if (!player.lobbyId) return;
    const lobby = lobbies.get(player.lobbyId);
    const previousId = player.lobbyId;
    player.lobbyId = null;
    player.ready = false;
    if (!lobby) return;

    lobby.players.delete(player.id);
    if (notify) writePacket(player.socket, 'lobby.left', { lobby_id: previousId });
    if (lobby.players.size === 0) {
      lobbies.delete(lobby.id);
      return;
    }

    if (lobby.hostId === player.id) {
      lobby.hostId = lobby.players.keys().next().value;
      const newHost = lobby.players.get(lobby.hostId);
      if (newHost) newHost.ready = true;
    }
    broadcastLobby(lobby);
  }

  function handlePacket(player, packet) {
    const type = typeof packet.type === 'string' ? packet.type : '';
    const payload = packet.payload && typeof packet.payload === 'object' && !Array.isArray(packet.payload)
      ? packet.payload
      : {};
    const requestId = packet.request_id ?? null;
    debugLog(`${player.id.slice(0, 8)} <- ${type || 'invalid'} request_id=${requestId}`);

    if (type === 'session.hello') {
      if (Number(payload.protocol) !== PROTOCOL_VERSION) {
        sendError(player, requestId, 'PROTOCOL_MISMATCH', 'Версия клиента не поддерживается');
        return;
      }
      player.name = normalizeName(payload.player_name);
      player.hasSession = true;
      writePacket(player.socket, 'session.welcome', {
        player_id: player.id,
        protocol: PROTOCOL_VERSION,
      }, requestId);
      if (player.lobbyId) {
        const lobby = lobbies.get(player.lobbyId);
        if (lobby) broadcastLobby(lobby);
      }
      return;
    }

    if (!player.hasSession) {
      sendError(player, requestId, 'SESSION_REQUIRED', 'Сначала требуется session.hello');
      return;
    }

    if (type === 'lobby.create') {
      if (player.lobbyId) {
        sendError(player, requestId, 'ALREADY_IN_LOBBY', 'Сначала выйдите из текущего лобби');
        return;
      }
      const settings = normalizeSettings(payload.settings);
      const id = createLobbyCode(lobbies);
      const lobby = {
        id,
        hostId: player.id,
        settings,
        players: new Map([[player.id, player]]),
        started: false,
      };
      player.lobbyId = id;
      player.ready = true;
      lobbies.set(id, lobby);
      writePacket(player.socket, 'lobby.created', snapshot(lobby), requestId);
      return;
    }

    if (type === 'lobby.join') {
      if (player.lobbyId) {
        sendError(player, requestId, 'ALREADY_IN_LOBBY', 'Сначала выйдите из текущего лобби');
        return;
      }
      const code = normalizeCode(payload.lobby_id);
      const lobby = lobbies.get(code);
      if (!lobby) {
        sendError(player, requestId, 'LOBBY_NOT_FOUND', 'Лобби с таким кодом не найдено');
        return;
      }
      if (lobby.started) {
        sendError(player, requestId, 'MATCH_ALREADY_STARTED', 'Матч в этом лобби уже начался');
        return;
      }
      if (lobby.players.size >= lobby.settings.max_players) {
        sendError(player, requestId, 'LOBBY_FULL', 'Лобби заполнено');
        return;
      }
      lobby.players.set(player.id, player);
      player.lobbyId = lobby.id;
      player.ready = false;
      writePacket(player.socket, 'lobby.joined', snapshot(lobby), requestId);
      broadcastLobby(lobby);
      return;
    }

    if (type === 'lobby.leave') {
      const lobby = getPlayerLobby(player, payload.lobby_id, requestId);
      if (lobby) leaveLobby(player, { notify: true });
      return;
    }

    if (type === 'lobby.invite') {
      const lobby = getPlayerLobby(player, payload.lobby_id, requestId);
      if (lobby) {
        writePacket(player.socket, 'lobby.invite', {
          lobby_id: lobby.id,
          invite_code: lobby.id,
        }, requestId);
      }
      return;
    }

    if (type === 'lobby.ready') {
      const lobby = getPlayerLobby(player, payload.lobby_id, requestId);
      if (!lobby) return;
      if (lobby.started) {
        sendError(player, requestId, 'MATCH_ALREADY_STARTED', 'Матч уже начался');
        return;
      }
      player.ready = player.id === lobby.hostId || payload.ready === true;
      broadcastLobby(lobby);
      return;
    }

    if (type === 'lobby.settings') {
      const lobby = getPlayerLobby(player, payload.lobby_id, requestId);
      if (!lobby) return;
      if (lobby.hostId !== player.id) {
        sendError(player, requestId, 'NOT_HOST', 'Только хост может менять настройки');
        return;
      }
      if (lobby.started) {
        sendError(player, requestId, 'MATCH_ALREADY_STARTED', 'Матч уже начался');
        return;
      }
      const settings = normalizeSettings(payload.settings);
      if (settings.max_players < lobby.players.size) {
        sendError(player, requestId, 'TOO_MANY_PLAYERS', 'Нельзя установить лимит ниже текущего числа игроков');
        return;
      }
      lobby.settings = settings;
      broadcastLobby(lobby);
      return;
    }

    if (type === 'lobby.start') {
      const lobby = getPlayerLobby(player, payload.lobby_id, requestId);
      if (!lobby) return;
      if (lobby.hostId !== player.id) {
        sendError(player, requestId, 'NOT_HOST', 'Только хост может начать матч');
        return;
      }
      if (!canStart(lobby)) {
        sendError(player, requestId, 'LOBBY_NOT_READY', statusMessage(lobby));
        return;
      }
      lobby.started = true;
      broadcast(lobby, 'lobby.started', {
        lobby_id: lobby.id,
        match_id: randomUUID(),
        seed: randomInt(1, 2_147_483_647),
        settings: { ...lobby.settings },
        players: publicPlayers(lobby),
      });
      return;
    }

    sendError(player, requestId, 'UNKNOWN_PACKET', 'Неизвестный тип пакета');
  }

  const server = net.createServer((socket) => {
    socket.setEncoding('utf8');
    socket.setNoDelay(true);
    socket.setKeepAlive(true, 30_000);
    debugLog(`connected ${socket.remoteAddress ?? 'unknown'}:${socket.remotePort ?? 'unknown'}`);

    const player = {
      id: randomUUID(),
      name: 'Игрок',
      socket,
      lobbyId: null,
      ready: false,
      hasSession: false,
    };
    let buffer = '';
    let rateWindowStartedAt = Date.now();
    let packetsInWindow = 0;

    socket.on('data', (chunk) => {
      buffer += chunk;
      let newlineIndex = buffer.indexOf('\n');
      while (newlineIndex !== -1) {
        const line = buffer.slice(0, newlineIndex).trim();
        buffer = buffer.slice(newlineIndex + 1);
        newlineIndex = buffer.indexOf('\n');
        if (!line) continue;
        if (Buffer.byteLength(line, 'utf8') > MAX_PACKET_BYTES) {
          writePacket(socket, 'error', { code: 'PACKET_TOO_LARGE', message: 'Пакет слишком большой' });
          socket.destroy();
          return;
        }

        const now = Date.now();
        if (now - rateWindowStartedAt >= 1_000) {
          rateWindowStartedAt = now;
          packetsInWindow = 0;
        }
        packetsInWindow += 1;
        if (packetsInWindow > RATE_LIMIT_PER_SECOND) {
          writePacket(socket, 'error', { code: 'RATE_LIMIT', message: 'Слишком много запросов' });
          socket.destroy();
          return;
        }

        let packet;
        try {
          packet = JSON.parse(line);
        } catch {
          writePacket(socket, 'error', { code: 'INVALID_JSON', message: 'Некорректный JSON' });
          continue;
        }
        if (!packet || typeof packet !== 'object' || Array.isArray(packet)) {
          writePacket(socket, 'error', { code: 'INVALID_PACKET', message: 'Некорректный пакет' });
          continue;
        }
        handlePacket(player, packet);
      }

      if (Buffer.byteLength(buffer, 'utf8') > MAX_PACKET_BYTES) {
        writePacket(socket, 'error', { code: 'PACKET_TOO_LARGE', message: 'Пакет слишком большой' });
        socket.destroy();
      }
    });

    socket.on('error', (error) => {
      logger.warn?.(`TCP client error: ${error.message}`);
    });
    socket.on('close', () => {
      debugLog(`closed ${player.id.slice(0, 8)}`);
      leaveLobby(player);
    });
  });

  server.on('error', (error) => logger.error?.(`TCP server error: ${error.message}`));
  server.lobbies = lobbies;
  return server;
}
