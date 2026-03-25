#!/usr/bin/env node

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

type BumpType = 'patch' | 'minor' | 'major';

interface SavedConfig {
  username?: string;
  image?: string;
  platform?: string;
  context?: string;
  latest?: boolean;
  login?: boolean;
  lastVersion?: string;
}

interface PublishConfig {
  version: string | null;
  username: string;
  image: string;
  platform: string;
  context: string;
  latest: boolean;
  login: boolean;
  bump: BumpType | null;
}

const PROJECT_ROOT = path.resolve(__dirname, '..');
const DEFAULTS_PATH = path.join(PROJECT_ROOT, '.publish-dockerhub.json');
const DEFAULT_DOCKERHUB_USERNAME = 'tenjojeremy';

function loadSavedConfig(): SavedConfig {
  if (!fs.existsSync(DEFAULTS_PATH)) {
    return {};
  }
  try {
    return JSON.parse(fs.readFileSync(DEFAULTS_PATH, 'utf8')) as SavedConfig;
  } catch {
    return {};
  }
}

function saveConfig(config: PublishConfig): void {
  const persisted: SavedConfig = {
    username: config.username,
    image: config.image,
    platform: config.platform,
    context: config.context,
    latest: config.latest,
    login: config.login,
    lastVersion: config.version ?? undefined,
  };
  fs.writeFileSync(DEFAULTS_PATH, `${JSON.stringify(persisted, null, 2)}\n`);
}

function readProjectVersion(): string | null {
  try {
    const pkg = JSON.parse(
      fs.readFileSync(path.join(PROJECT_ROOT, 'package.json'), 'utf8'),
    ) as { version?: string };
    return pkg.version ? `v${pkg.version}` : null;
  } catch {
    return null;
  }
}

function bumpVersion(version: string, bumpType: BumpType): string {
  const match = String(version)
    .trim()
    .match(/^v?(\d+)\.(\d+)\.(\d+)$/);
  if (!match) {
    throw new Error(
      `Cannot bump version '${version}'. Expected semantic version like v1.2.3.`,
    );
  }

  let major = Number(match[1]);
  let minor = Number(match[2]);
  let patch = Number(match[3]);

  if (bumpType === 'major') {
    major += 1;
    minor = 0;
    patch = 0;
  } else if (bumpType === 'minor') {
    minor += 1;
    patch = 0;
  } else {
    patch += 1;
  }

  return `v${major}.${minor}.${patch}`;
}

function printHelp(): void {
  console.log(`Usage:
  tsx scripts/publish-dockerhub.ts <version> [options]

Options:
  --username <name>     Docker Hub username (default: tenjojeremy)
  --image <name>        Image name (default: body-gen-comfyui)
  --platform <value>    Build platform (default: linux/amd64)
  --context <path>      Docker build context (default: .)
  --bump <type>         Auto-bump version: patch | minor | major
  --latest              Also tag and push :latest
  --no-login            Skip 'docker login'
  -h, --help            Show this help message

Examples:
  tsx scripts/publish-dockerhub.ts v1 --username jeremytenjo
  tsx scripts/publish-dockerhub.ts --bump patch --latest
  DOCKERHUB_USERNAME=tenjojeremy tsx scripts/publish-dockerhub.ts v1.1 --latest

If <version> or --username are not provided, the script will prompt for them.
The script saves your last successful values to .publish-dockerhub.json.
`);
}

function run(cmd: string, args: string[]): void {
  console.log(`\n$ ${cmd} ${args.join(' ')}`);
  const result = spawnSync(cmd, args, { stdio: 'inherit' });
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

function parseArgs(argv: string[], config: PublishConfig): void {
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith('-') && !config.version) {
      config.version = arg;
      continue;
    }

    if (arg === '--username') {
      config.username = argv[++i] || '';
    } else if (arg === '--image') {
      config.image = argv[++i] || config.image;
    } else if (arg === '--platform') {
      config.platform = argv[++i] || config.platform;
    } else if (arg === '--context') {
      config.context = argv[++i] || config.context;
    } else if (arg === '--bump') {
      const bump = (argv[++i] || '').toLowerCase();
      if (bump !== 'patch' && bump !== 'minor' && bump !== 'major') {
        console.error(`Invalid --bump value: ${bump}`);
        printHelp();
        process.exit(1);
      }
      config.bump = bump;
    } else if (arg === '--latest') {
      config.latest = true;
    } else if (arg === '--no-login') {
      config.login = false;
    } else {
      console.error(`Unknown argument: ${arg}`);
      printHelp();
      process.exit(1);
    }
  }
}

async function promptForRequired(
  config: PublishConfig,
  savedConfig: SavedConfig,
): Promise<void> {
  if (config.version && config.username) {
    return;
  }

  if (!process.stdout.isTTY) {
    if (!config.version) {
      console.error(
        'Missing required <version> argument in non-interactive mode.',
      );
    }
    if (!config.username) {
      console.error('Missing Docker Hub username in non-interactive mode.');
    }
    process.exit(1);
  }

  const clack = await import('@clack/prompts');
  const { intro, text, isCancel, cancel, outro } = clack;

  intro('Docker Hub publish setup');

  if (!config.version) {
    const version = await text({
      message: 'Version tag to publish',
      placeholder: 'v1.2.0',
      initialValue:
        savedConfig.lastVersion || readProjectVersion() || undefined,
      validate(value) {
        if (!value || !String(value).trim()) {
          return 'Version is required';
        }
        return undefined;
      },
    });

    if (isCancel(version)) {
      cancel('Publish cancelled.');
      process.exit(1);
    }
    config.version = String(version).trim();
  }

  if (!config.username) {
    const username = await text({
      message: 'Docker Hub username',
      placeholder: 'your-dockerhub-username',
      initialValue:
        savedConfig.username ||
        process.env.DOCKERHUB_USERNAME ||
        DEFAULT_DOCKERHUB_USERNAME,
      validate(value) {
        if (!value || !String(value).trim()) {
          return 'Docker Hub username is required';
        }
        return undefined;
      },
    });

    if (isCancel(username)) {
      cancel('Publish cancelled.');
      process.exit(1);
    }
    config.username = String(username).trim();
  }

  outro('Using prompted values for publish.');
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  if (argv.includes('-h') || argv.includes('--help')) {
    printHelp();
    process.exit(0);
  }

  const savedConfig = loadSavedConfig();
  const config: PublishConfig = {
    version: null,
    username:
      process.env.DOCKERHUB_USERNAME ||
      savedConfig.username ||
      DEFAULT_DOCKERHUB_USERNAME,
    image: savedConfig.image || 'body-gen-comfyui',
    platform: savedConfig.platform || 'linux/amd64',
    context: savedConfig.context || '.',
    latest: savedConfig.latest || false,
    login: savedConfig.login !== undefined ? savedConfig.login : true,
    bump: null,
  };

  parseArgs(argv, config);

  if (!config.version && config.bump) {
    const baseVersion = savedConfig.lastVersion || readProjectVersion();
    if (!baseVersion) {
      console.error(
        'Cannot use --bump without a base version. Publish once with an explicit version first.',
      );
      process.exit(1);
    }
    config.version = bumpVersion(baseVersion, config.bump);
    console.log(`Auto-bumped version: ${baseVersion} -> ${config.version}`);
  }

  await promptForRequired(config, savedConfig);

  const imageRef = `${config.username}/${config.image}:${config.version}`;
  const latestRef = `${config.username}/${config.image}:latest`;

  console.log('Publishing Docker image with configuration:');
  console.log(`- image:    ${config.username}/${config.image}`);
  console.log(`- version:  ${config.version}`);
  console.log(`- platform: ${config.platform}`);
  console.log(`- context:  ${config.context}`);

  if (config.login) {
    run('docker', ['login']);
  }

  run('docker', [
    'build',
    '--platform',
    config.platform,
    '-t',
    imageRef,
    config.context,
  ]);

  run('docker', ['push', imageRef]);

  if (config.latest) {
    run('docker', ['tag', imageRef, latestRef]);
    run('docker', ['push', latestRef]);
  }

  console.log('\nDone.');
  console.log(`Published: ${imageRef}`);
  if (config.latest) {
    console.log(`Published: ${latestRef}`);
  }

  saveConfig(config);
}

main().catch((error: unknown) => {
  console.error(error);
  process.exit(1);
});
