import assert from 'node:assert/strict';
import net from 'node:net';
import { once } from 'node:events';
import test from 'node:test';
import { createLobbyServer } from '../src/lobby-server.js';

function createTestClient(port) {
  const socket = net.createConnection({ host: '127.0.0.1', port });
  socket.setEncoding('utf8');
  let buffer = '';
  let requestId = 0;
  const queued = [];
  const waiters = [];

  function dispatch(packet) {
    const index = waiters.findIndex(({ type, predicate }) => (
      packet.type === type && (!predicate || predicate(packet.payload))
    ));
    if (index === -1) queued.push(packet);
    else waiters.splice(index, 1)[0].resolve(packet);
  }

  socket.on('data', (chunk) => {
    buffer += chunk;
    while (buffer.includes('\n')) {
      const newline = buffer.indexOf('\n');
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      if (line) dispatch(JSON.parse(line));
    }
  });

  return {
    socket,
    async connected() {
      if (!socket.connecting) return;
      await once(socket, 'connect');
    },
    send(type, payload = {}) {
      requestId += 1;
      socket.write(`${JSON.stringify({ type, request_id: requestId, payload })}\n`);
    },
    waitFor(type, predicate = null, timeoutMs = 2_000) {
      const index = queued.findIndex((packet) => (
        packet.type === type && (!predicate || predicate(packet.payload))
      ));
      if (index !== -1) return Promise.resolve(queued.splice(index, 1)[0]);
      return new Promise((resolve, reject) => {
        const waiter = { type, predicate, resolve };
        waiters.push(waiter);
        const timeout = setTimeout(() => {
          const waiterIndex = waiters.indexOf(waiter);
          if (waiterIndex !== -1) waiters.splice(waiterIndex, 1);
          reject(new Error(`Timed out waiting for ${type}`));
        }, timeoutMs);
        waiter.resolve = (packet) => {
          clearTimeout(timeout);
          resolve(packet);
        };
      });
    },
    close() {
      socket.destroy();
    },
  };
}

async function startServer() {
  const server = createLobbyServer({ logger: { warn() {}, error() {} } });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return { server, port: server.address().port };
}

async function hello(client, name) {
  await client.connected();
  client.send('session.hello', { protocol: 1, player_name: name });
  return client.waitFor('session.welcome');
}

test('create, configure, ready and start a lobby over TCP', async (t) => {
  const { server, port } = await startServer();
  const host = createTestClient(port);
  const guest = createTestClient(port);
  t.after(async () => {
    host.close();
    guest.close();
    await new Promise((resolve) => server.close(resolve));
  });

  const hostWelcome = await hello(host, 'Host');
  await hello(guest, 'Guest');

  host.send('lobby.create', {
    settings: { max_players: 3, round_time: 120, wins_to_match: 3 },
  });
  const created = await host.waitFor('lobby.created');
  assert.match(created.payload.lobby_id, /^[A-Z2-9]{6}$/);
  assert.equal(created.payload.host_id, hostWelcome.payload.player_id);
  assert.equal(created.payload.settings.round_time, 120);
  assert.equal(created.payload.can_start, false);

  guest.send('lobby.join', { lobby_id: created.payload.lobby_id.toLowerCase() });
  const joined = await guest.waitFor('lobby.joined');
  assert.equal(joined.payload.players.length, 2);
  assert.equal(joined.payload.can_start, false);
  await host.waitFor('lobby.updated', (payload) => payload.players.length === 2);

  host.send('lobby.start', { lobby_id: created.payload.lobby_id });
  const blocked = await host.waitFor('error');
  assert.equal(blocked.payload.code, 'LOBBY_NOT_READY');

  guest.send('lobby.ready', { lobby_id: created.payload.lobby_id, ready: true });
  const readyState = await host.waitFor('lobby.updated', (payload) => payload.can_start === true);
  assert.equal(readyState.payload.players.find((player) => player.name === 'Guest').ready, true);

  host.send('lobby.settings', {
    lobby_id: created.payload.lobby_id,
    settings: { max_players: 2, round_time: 60, wins_to_match: 1 },
  });
  const configured = await host.waitFor(
    'lobby.updated',
    (payload) => payload.settings.round_time === 60,
  );
  assert.equal(configured.payload.can_start, true);

  host.send('lobby.start', { lobby_id: created.payload.lobby_id });
  const [hostStarted, guestStarted] = await Promise.all([
    host.waitFor('lobby.started'),
    guest.waitFor('lobby.started'),
  ]);
  assert.equal(hostStarted.payload.match_id, guestStarted.payload.match_id);
  assert.equal(hostStarted.payload.seed, guestStarted.payload.seed);
  assert.deepEqual(hostStarted.payload.settings, guestStarted.payload.settings);
  assert.equal(hostStarted.payload.players.length, 2);
  assert.deepEqual(hostStarted.payload.players.map((player) => player.spawn_slot), [0, 1]);

  host.send('game.input', {
    match_id: hostStarted.payload.match_id,
    position: { x: -3.25, y: 0.1, z: 1.5 },
    velocity: { x: 4, y: 0, z: 0 },
    yaw: 1.25,
  });
  const gameState = await guest.waitFor('game.state', (payload) => (
    payload.players.some((member) => member.id === hostWelcome.payload.player_id
      && member.position.x === -3.25)
  ));
  assert.equal(gameState.payload.players.length, 2);

  host.send('game.hit', {
    match_id: hostStarted.payload.match_id,
    target_id: joined.payload.players.find((member) => member.id !== hostWelcome.payload.player_id).id,
    damage: 1,
    knockback: { x: 5, y: 1, z: 0 },
  });
  const hit = await guest.waitFor('game.hit');
  assert.equal(hit.payload.health, 2);

  host.send('game.round.reset', { match_id: hostStarted.payload.match_id });
  const reset = await guest.waitFor('game.round.started');
  assert.ok(reset.payload.players.every((member) => member.health === 3));
});

test('host ownership transfers when the host leaves', async (t) => {
  const { server, port } = await startServer();
  const host = createTestClient(port);
  const guest = createTestClient(port);
  t.after(async () => {
    host.close();
    guest.close();
    await new Promise((resolve) => server.close(resolve));
  });

  await hello(host, 'First host');
  const guestWelcome = await hello(guest, 'New host');
  host.send('lobby.create', { settings: {} });
  const created = await host.waitFor('lobby.created');
  guest.send('lobby.join', { lobby_id: created.payload.lobby_id });
  await guest.waitFor('lobby.joined');
  host.send('lobby.leave', { lobby_id: created.payload.lobby_id });

  const updated = await guest.waitFor(
    'lobby.updated',
    (payload) => payload.host_id === guestWelcome.payload.player_id,
  );
  assert.equal(updated.payload.players[0].is_host, true);
});
