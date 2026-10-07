import { spawn } from 'node:child_process';
import net from 'node:net';

import { config } from '../config.js';

/** true si un serveur écoute déjà sur ce port local. */
function isListening(port) {
  return new Promise((resolve) => {
    const socket = net.connect({ host: '127.0.0.1', port });
    socket.setTimeout(1_000);
    socket.once('connect', () => {
      socket.destroy();
      resolve(true);
    });
    socket.once('error', () => resolve(false));
    socket.once('timeout', () => {
      socket.destroy();
      resolve(false);
    });
  });
}

/**
 * Ouvre un tunnel SSH vers le MySQL du serveur distant (qui n'écoute que
 * sur sa propre machine) : 127.0.0.1:SSH_TUNNEL_LOCAL_PORT → DB_HOST:DB_PORT
 * vu depuis le serveur. Sans SSH_TUNNEL_HOST, ne fait rien. Un tunnel déjà
 * ouvert sur le port local (autre terminal, DBeaver…) est réutilisé.
 */
export async function openTunnel() {
  const tunnel = config.sshTunnel;
  if (!tunnel) return;
  if (await isListening(tunnel.localPort)) return;

  const args = [
    '-N',
    '-L', `${tunnel.localPort}:${config.db.host}:${config.db.port}`,
    '-p', String(tunnel.port),
    '-o', 'ExitOnForwardFailure=yes',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', 'ServerAliveInterval=30',
    '-o', 'ConnectTimeout=10',
    '-o', 'BatchMode=yes',
    ...(tunnel.key ? ['-i', tunnel.key] : []),
    `${tunnel.user}@${tunnel.host}`,
  ];
  const child = spawn('ssh', args, { stdio: ['ignore', 'ignore', 'pipe'], windowsHide: true });
  child.unref();
  process.once('exit', () => child.kill());

  // Raison donnée par ssh (clé refusée, hôte injoignable…), reprise dans l'erreur.
  let reason = '';
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (chunk) => (reason += chunk));
  let exited = false;
  child.once('exit', () => (exited = true));
  child.once('error', (error) => {
    exited = true;
    reason ||= error.code === 'ENOENT' ? 'commande ssh introuvable' : error.message;
  });

  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline && !exited) {
    if (await isListening(tunnel.localPort)) {
      child.stderr.unref();
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 300));
  }
  child.kill();
  throw new Error(
    `Tunnel SSH vers ${tunnel.user}@${tunnel.host} impossible à ouvrir : ${reason.trim() || 'délai dépassé'}` +
      ' (pour travailler sur le MySQL de WAMP, videz SSH_TUNNEL_HOST dans .env)',
  );
}
