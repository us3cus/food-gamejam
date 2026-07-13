import { createLobbyServer } from './lobby-server.js';

const host = process.env.TCP_HOST || '127.0.0.1';
const parsedPort = Number.parseInt(process.env.TCP_PORT || '7778', 10);
const port = Number.isInteger(parsedPort) && parsedPort > 0 && parsedPort <= 65_535
  ? parsedPort
  : 7778;
const debug = process.env.TCP_LOG_LEVEL === 'debug';

const server = createLobbyServer({ debug });

server.listen(port, host, () => {
  console.log(`Foodfight TCP server listening on ${host}:${port}; debug=${debug}`);
});

function shutdown(signal) {
  console.log(`${signal}: closing TCP server`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 5_000).unref();
}

process.once('SIGINT', () => shutdown('SIGINT'));
process.once('SIGTERM', () => shutdown('SIGTERM'));
