import net from 'node:net';
import { randomBytes, randomInt, randomUUID } from 'node:crypto';

const PROTOCOL_VERSION = 1;
const MAX_PACKET_BYTES = 1_048_576;
const RATE_LIMIT_PER_SECOND = 60;
const GAME_STATE_INTERVAL_MS = 50;
const FOOD_SPAWN_INTERVAL_MS = 2_500;
const MAX_FOOD_ITEMS = 6;
const PROJECTILE_LIFETIME_MS = 6_000;
const LOBBY_CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const FOOD_TYPES = new Map([
  ['tomato', { weight: 3, damage: 1, aoe: false }],
  ['cheese', { weight: 3, damage: 1, aoe: false }],
  ['pumpkin', { weight: 2, damage: 2, aoe: false }],
  ['watermelon', { weight: 1, damage: 1, aoe: true }],
]);

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
    max_players: 2,
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
  const matches = new Map();

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
    if (lobby.started || lobby.players.size !== 2) return false;
    return [...lobby.players.values()].every(
      (player) => player.id === lobby.hostId || player.ready,
    );
  }

  function statusMessage(lobby) {
    if (lobby.started) return 'Матч уже запущен';
    if (lobby.players.size !== 2) return 'Для PvP нужны ровно два игрока';
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

    if (lobby.matchId) {
      const match = matches.get(lobby.matchId);
      if (match) broadcast(lobby, 'game.player_left', {
        match_id: match.id,
        player_id: player.id,
        message: 'Второй игрок отключился',
      });
      matches.delete(lobby.matchId);
      for (const member of lobby.players.values()) {
        member.lobbyId = null;
        member.ready = false;
      }
      lobbies.delete(lobby.id);
      return;
    }

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
        matchId: null,
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
      const match = createMatch(lobby);
      lobby.matchId = match.id;
      matches.set(match.id, match);
      broadcast(lobby, 'lobby.started', {
        lobby_id: lobby.id,
        match_id: match.id,
        host_id: lobby.hostId,
        seed: randomInt(1, 2_147_483_647),
        settings: { ...lobby.settings },
        players: matchPlayers(match),
        items: publicItems(match),
      });
      broadcastGameState(match);
      return;
    }

    if (type === 'game.input') {
      const match = getPlayerMatch(player, payload.match_id, requestId);
      if (!match) return;
      const state = match.players.get(player.id);
      const position = vector(payload.position);
      const velocity = vector(payload.velocity);
      const yaw = Number(payload.yaw);
      if (!position || !velocity || !Number.isFinite(yaw)) {
        sendError(player, requestId, 'INVALID_INPUT', 'Некорректное состояние игрока');
        return;
      }
      state.position = {
        x: clamp(position.x, -12, 12),
        y: clamp(position.y, -8, 20),
        z: clamp(position.z, -12, 12),
      };
      state.velocity = {
        x: clamp(velocity.x, -25, 25),
        y: clamp(velocity.y, -25, 25),
        z: clamp(velocity.z, -25, 25),
      };
      state.yaw = clamp(yaw, -Math.PI * 4, Math.PI * 4);
      return;
    }

    if (type === 'game.item.pickup') {
      const match = getPlayerMatch(player, payload.match_id, requestId);
      if (!match) return;
      const state = match.players.get(player.id);
      const item = match.items.get(String(payload.item_id ?? ''));
      if (!item || state.heldFood || Date.now() < item.pickupAvailableAt
          || flatDistance(state.position, item.position) > 1.75) {
        sendError(player, requestId, 'ITEM_NOT_AVAILABLE', 'Предмет уже подобран или находится слишком далеко');
        return;
      }
      match.items.delete(item.id);
      state.heldFood = item.foodType;
      broadcastMatch(match, 'game.item.picked', {
        match_id: match.id,
        item_id: item.id,
        player_id: player.id,
        food_type: item.foodType,
      });
      return;
    }

    if (type === 'game.item.drop') {
      const match = getPlayerMatch(player, payload.match_id, requestId);
      if (!match) return;
      const state = match.players.get(player.id);
      const requestedPosition = vector(payload.position);
      if (!state.heldFood || !requestedPosition
          || flatDistance(state.position, requestedPosition) > 3) {
        sendError(player, requestId, 'INVALID_ITEM_DROP', 'Нельзя выбросить этот предмет');
        return;
      }
      const foodType = state.heldFood;
      state.heldFood = null;
      const item = spawnFoodItem(match, {
        foodType,
        position: {
          x: clamp(requestedPosition.x, -10, 10),
          y: clamp(requestedPosition.y, 0.1, 2),
          z: clamp(requestedPosition.z, -10, 10),
        },
        pickupDelayMs: 750,
      });
      broadcastMatch(match, 'game.item.spawn', publicItem(match, item));
      return;
    }

    if (type === 'game.item.hit') {
      const match = getPlayerMatch(player, payload.match_id, requestId);
      if (!match) return;
      const target = match.players.get(String(payload.target_id ?? ''));
      const item = match.items.get(String(payload.item_id ?? ''));
      const knockback = vector(payload.knockback);
      if (!item || item.bonked || !target || target.id !== player.id || !knockback
          || flatDistance(target.position, item.position) > 1.75 || target.health <= 0) {
        sendError(player, requestId, 'INVALID_ITEM_HIT', 'Некорректное попадание падающим предметом');
        return;
      }
      item.bonked = true;
      target.health = Math.max(0, target.health - 1);
      broadcastMatch(match, 'game.hit', {
        match_id: match.id,
        source_id: `item:${item.id}`,
        target_id: target.id,
        damage: 1,
        health: target.health,
        knockback: clampedVector(knockback, 20),
      });
      return;
    }

    if (type === 'game.item.despawn') {
      const match = getPlayerMatch(player, payload.match_id, requestId);
      if (!match) return;
      const item = match.items.get(String(payload.item_id ?? ''));
      if (!item || match.hostId !== player.id) return;
      match.items.delete(item.id);
      broadcastMatch(match, 'game.item.despawn', {
        match_id: match.id,
        item_id: item.id,
      });
      return;
    }

    if (type === 'game.projectile.spawn') {
      const match = getPlayerMatch(player, payload.match_id, requestId);
      if (!match) return;
      const state = match.players.get(player.id);
      const origin = vector(payload.origin);
      const velocity = vector(payload.velocity);
      const multiplier = Number(payload.knockback_multiplier);
      if (!state.heldFood || !origin || !velocity || !Number.isFinite(multiplier)
          || String(payload.food_type ?? '') !== state.heldFood
          || distance(state.position, origin) > 3.5 || magnitude(velocity) > 40) {
        sendError(player, requestId, 'INVALID_PROJECTILE', 'Некорректные параметры броска');
        return;
      }
      const config = FOOD_TYPES.get(state.heldFood);
      if (!config) {
        sendError(player, requestId, 'INVALID_FOOD_TYPE', 'Неизвестный тип предмета');
        return;
      }
      const projectile = {
        id: randomUUID(),
        sourceId: player.id,
        foodType: state.heldFood,
        origin: clampedVector(origin, 20),
        velocity: clampedVector(velocity, 40),
        knockbackMultiplier: clamp(multiplier, 1, 1.5),
        damage: config.damage,
        aoe: config.aoe,
        createdAt: Date.now(),
        hitTargets: new Set(),
      };
      state.heldFood = null;
      match.projectiles.set(projectile.id, projectile);
      broadcastMatch(match, 'game.projectile.spawn', {
        match_id: match.id,
        projectile_id: projectile.id,
        source_id: projectile.sourceId,
        food_type: projectile.foodType,
        origin: projectile.origin,
        velocity: projectile.velocity,
        knockback_multiplier: projectile.knockbackMultiplier,
        server_time: projectile.createdAt,
      });
      return;
    }

    if (type === 'game.projectile.hit') {
      const match = getPlayerMatch(player, payload.match_id, requestId);
      if (!match) return;
      const projectile = match.projectiles.get(String(payload.projectile_id ?? ''));
      const target = match.players.get(String(payload.target_id ?? ''));
      const knockback = vector(payload.knockback);
      if (!projectile || projectile.sourceId !== player.id || !target || !knockback
          || projectile.hitTargets.has(target.id) || target.health <= 0
          || (!projectile.aoe && projectile.hitTargets.size > 0)) {
        sendError(player, requestId, 'INVALID_PROJECTILE_HIT', 'Некорректное попадание проджектайлом');
        return;
      }
      projectile.hitTargets.add(target.id);
      target.health = Math.max(0, target.health - projectile.damage);
      broadcastMatch(match, 'game.hit', {
        match_id: match.id,
        source_id: projectile.sourceId,
        projectile_id: projectile.id,
        target_id: target.id,
        damage: projectile.damage,
        health: target.health,
        knockback: clampedVector(knockback, 20),
      });
      return;
    }

    if (type === 'game.projectile.despawn') {
      const match = getPlayerMatch(player, payload.match_id, requestId);
      if (!match) return;
      const projectile = match.projectiles.get(String(payload.projectile_id ?? ''));
      if (!projectile || projectile.sourceId !== player.id) return;
      match.projectiles.delete(projectile.id);
      broadcastMatch(match, 'game.projectile.despawn', {
        match_id: match.id,
        projectile_id: projectile.id,
      });
      return;
    }

    if (type === 'game.hit') {
      const match = getPlayerMatch(player, payload.match_id, requestId);
      if (!match) return;
      const source = match.players.get(player.id);
      const target = match.players.get(String(payload.target_id ?? ''));
      const damage = Number(payload.damage);
      const knockback = vector(payload.knockback);
      if (!target || target.id === source.id || !Number.isInteger(damage)
          || damage < 1 || damage > 2 || !knockback) {
        sendError(player, requestId, 'INVALID_HIT', 'Некорректное попадание');
        return;
      }
      const now = Date.now();
      if (now - source.lastHitAt < 120 || target.health <= 0) return;
      source.lastHitAt = now;
      target.health = Math.max(0, target.health - damage);
      broadcastMatch(match, 'game.hit', {
        match_id: match.id,
        source_id: source.id,
        target_id: target.id,
        damage,
        health: target.health,
        knockback: {
          x: clamp(knockback.x, -20, 20),
          y: clamp(knockback.y, -20, 20),
          z: clamp(knockback.z, -20, 20),
        },
      });
      return;
    }

    if (type === 'game.round.reset') {
      const match = getPlayerMatch(player, payload.match_id, requestId);
      if (!match) return;
      if (match.hostId !== player.id) {
        sendError(player, requestId, 'NOT_HOST', 'Только хост может запустить следующий раунд');
        return;
      }
      for (const state of match.players.values()) {
        state.position = spawnPosition(state.spawnSlot);
        state.velocity = { x: 0, y: 0, z: 0 };
        state.health = 3;
        state.heldFood = null;
      }
      match.items.clear();
      match.projectiles.clear();
      spawnFoodItem(match);
      match.nextItemSpawnAt = Date.now() + FOOD_SPAWN_INTERVAL_MS;
      broadcastMatch(match, 'game.round.started', {
        match_id: match.id,
        reset_match: payload.reset_match === true,
        players: matchPlayers(match),
        items: publicItems(match),
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
  const gameTimer = setInterval(() => {
    const now = Date.now();
    for (const match of matches.values()) {
      maintainMatchWorld(match, now);
      broadcastGameState(match);
    }
  }, GAME_STATE_INTERVAL_MS);
  gameTimer.unref();
  server.on('close', () => clearInterval(gameTimer));
  server.lobbies = lobbies;
  server.matches = matches;
  return server;

  function createMatch(lobby) {
    const match = {
      id: randomUUID(),
      lobbyId: lobby.id,
      hostId: lobby.hostId,
      players: new Map(),
      items: new Map(),
      projectiles: new Map(),
      nextItemSpawnAt: Date.now() + FOOD_SPAWN_INTERVAL_MS,
    };
    [...lobby.players.values()].forEach((member, spawnSlot) => match.players.set(member.id, {
      id: member.id,
      name: member.name,
      spawnSlot,
      position: spawnPosition(spawnSlot),
      velocity: { x: 0, y: 0, z: 0 },
      yaw: spawnSlot === 0 ? -Math.PI / 2 : Math.PI / 2,
      health: 3,
      lastHitAt: 0,
      heldFood: null,
    }));
    spawnFoodItem(match);
    return match;
  }

  function getPlayerMatch(player, suppliedId, requestId) {
    const lobby = lobbies.get(player.lobbyId);
    const match = typeof suppliedId === 'string' ? matches.get(suppliedId) : null;
    if (!lobby?.started || lobby.matchId !== suppliedId || !match?.players.has(player.id)) {
      sendError(player, requestId, 'NOT_IN_MATCH', 'Игрок не состоит в этом матче');
      return null;
    }
    return match;
  }

  function matchPlayers(match) {
    return [...match.players.values()].map((state) => ({
      id: state.id,
      name: state.name,
      spawn_slot: state.spawnSlot,
      spawn: spawnPosition(state.spawnSlot),
      position: state.position,
      velocity: state.velocity,
      yaw: state.yaw,
      health: state.health,
      held_food: state.heldFood || '',
    }));
  }

  function publicItem(match, item) {
    return {
      match_id: match.id,
      item_id: item.id,
      food_type: item.foodType,
      position: item.position,
      pickup_delay_ms: Math.max(0, item.pickupAvailableAt - Date.now()),
    };
  }

  function publicItems(match) {
    return [...match.items.values()].map((item) => publicItem(match, item));
  }

  function spawnFoodItem(match, { foodType = null, position = null, pickupDelayMs = 0 } = {}) {
    const angle = Math.random() * Math.PI * 2;
    const radius = Math.sqrt(Math.random()) * 7;
    const item = {
      id: randomUUID(),
      foodType: foodType || randomFoodType(),
      position: position || { x: Math.cos(angle) * radius, y: 9, z: Math.sin(angle) * radius },
      pickupAvailableAt: Date.now() + pickupDelayMs,
      bonked: false,
    };
    match.items.set(item.id, item);
    return item;
  }

  function maintainMatchWorld(match, now) {
    for (const projectile of match.projectiles.values()) {
      if (now - projectile.createdAt >= PROJECTILE_LIFETIME_MS) {
        match.projectiles.delete(projectile.id);
        broadcastMatch(match, 'game.projectile.despawn', {
          match_id: match.id,
          projectile_id: projectile.id,
        });
      }
    }
    if (match.items.size < MAX_FOOD_ITEMS && now >= match.nextItemSpawnAt) {
      const item = spawnFoodItem(match);
      match.nextItemSpawnAt = now + FOOD_SPAWN_INTERVAL_MS;
      broadcastMatch(match, 'game.item.spawn', publicItem(match, item));
    }
  }

  function broadcastGameState(match) {
    broadcastMatch(match, 'game.state', {
      match_id: match.id,
      server_time: Date.now(),
      players: matchPlayers(match),
      items: publicItems(match),
    });
  }

  function broadcastMatch(match, type, payload) {
    const lobby = lobbies.get(match.lobbyId);
    if (lobby) broadcast(lobby, type, payload);
  }
}

function spawnPosition(slot) {
  return { x: slot === 0 ? -4.5 : 4.5, y: 0.1, z: 0 };
}

function vector(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const x = Number(value.x);
  const y = Number(value.y);
  const z = Number(value.z);
  return Number.isFinite(x) && Number.isFinite(y) && Number.isFinite(z) ? { x, y, z } : null;
}

function clampedVector(value, limit) {
  return {
    x: clamp(value.x, -limit, limit),
    y: clamp(value.y, -limit, limit),
    z: clamp(value.z, -limit, limit),
  };
}

function magnitude(value) {
  return Math.hypot(value.x, value.y, value.z);
}

function distance(a, b) {
  return Math.hypot(a.x - b.x, a.y - b.y, a.z - b.z);
}

function flatDistance(a, b) {
  return Math.hypot(a.x - b.x, a.z - b.z);
}

function randomFoodType() {
  const totalWeight = [...FOOD_TYPES.values()].reduce((sum, config) => sum + config.weight, 0);
  let roll = Math.random() * totalWeight;
  for (const [foodType, config] of FOOD_TYPES) {
    roll -= config.weight;
    if (roll <= 0) return foodType;
  }
  return FOOD_TYPES.keys().next().value;
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value));
}
