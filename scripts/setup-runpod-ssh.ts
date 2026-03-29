#!/usr/bin/env node

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

interface ParsedSshCommand {
  user: string;
  host: string;
  port: number;
  identityFile: string;
}

function parseSshCommand(input: string): ParsedSshCommand | null {
  const trimmed = input.trim();
  const normalized = trimmed.startsWith('ssh ') ? trimmed : `ssh ${trimmed}`;

  const userHostMatch = normalized.match(/ssh\s+([^\s@]+)@([^\s]+)/);
  if (!userHostMatch) {
    return null;
  }

  const user = userHostMatch[1];
  const host = userHostMatch[2];

  const portMatch = normalized.match(/(?:^|\s)-p\s+(\d{1,5})(?:\s|$)/);
  const port = portMatch ? Number(portMatch[1]) : 22;
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    return null;
  }

  const identityMatch = normalized.match(/(?:^|\s)-i\s+([^\s]+)(?:\s|$)/);
  const identityFile = identityMatch?.[1] ?? '~/.ssh/id_ed25519';

  return { user, host, port, identityFile };
}

function removeHostBlock(configText: string, hostAlias: string): string {
  const lines = configText.split(/\r?\n/);
  const out: string[] = [];
  let skip = false;

  for (const line of lines) {
    const hostHeader = line.match(/^\s*Host\s+(.+)\s*$/);
    if (hostHeader) {
      const aliases = hostHeader[1].trim().split(/\s+/);
      if (skip) {
        skip = false;
      }
      if (aliases.includes(hostAlias)) {
        skip = true;
        continue;
      }
    }

    if (!skip) {
      out.push(line);
    }
  }

  return out.join('\n').replace(/\s+$/, '');
}

function hostBlock(alias: string, parsed: ParsedSshCommand): string {
  return [
    `Host ${alias}`,
    `  HostName ${parsed.host}`,
    `  User ${parsed.user}`,
    `  Port ${parsed.port}`,
    `  IdentityFile ${parsed.identityFile}`,
    '  IdentitiesOnly yes',
    '  ServerAliveInterval 30',
  ].join('\n');
}

async function main(): Promise<void> {
  const clack = await import('@clack/prompts');
  const { intro, outro, text, isCancel, cancel, note } = clack;

  if (!process.stdout.isTTY) {
    console.error('Interactive TTY required to run this setup.');
    process.exit(1);
  }

  intro('RunPod SSH config setup');

  const alias = await text({
    message: 'SSH host alias for VS Code',
    placeholder: 'runpod-current',
    initialValue: 'runpod-current',
    validate(value) {
      const v = String(value ?? '').trim();
      if (!v) {
        return 'Alias is required.';
      }
      if (/\s/.test(v)) {
        return 'Alias cannot contain spaces.';
      }
      return undefined;
    },
  });
  if (isCancel(alias)) {
    cancel('Cancelled.');
    process.exit(1);
  }
  const resolvedAlias = String(alias).trim();

  const sshCommand = await text({
    message: 'Paste RunPod "SSH over exposed TCP" command',
    placeholder: 'ssh root@195.26.232.130 -p 36983 -i ~/.ssh/id_ed25519',
    validate(value) {
      const parsed = parseSshCommand(String(value ?? ''));
      if (!parsed) {
        return 'Could not parse SSH command.';
      }
      return undefined;
    },
  });
  if (isCancel(sshCommand)) {
    cancel('Cancelled.');
    process.exit(1);
  }

  const parsed = parseSshCommand(String(sshCommand));
  if (!parsed) {
    cancel('Invalid SSH command.');
    process.exit(1);
  }

  const sshDir = path.join(os.homedir(), '.ssh');
  const sshConfigPath = path.join(sshDir, 'config');
  fs.mkdirSync(sshDir, { recursive: true });

  const existing = fs.existsSync(sshConfigPath)
    ? fs.readFileSync(sshConfigPath, 'utf8')
    : '';

  const withoutAlias = removeHostBlock(existing, resolvedAlias);
  const next = `${withoutAlias}${withoutAlias ? '\n\n' : ''}${hostBlock(
    resolvedAlias,
    parsed,
  )}\n`;

  fs.writeFileSync(sshConfigPath, next, 'utf8');
  fs.chmodSync(sshConfigPath, 0o600);

  note(
    [
      `Alias: ${resolvedAlias}`,
      `Target: ${parsed.user}@${parsed.host}:${parsed.port}`,
      `Key: ${parsed.identityFile}`,
      `Config: ${sshConfigPath}`,
    ].join('\n'),
    'Updated SSH config',
  );

  outro(`Connect in VS Code with Remote-SSH host "${resolvedAlias}".`);
}

void main();
