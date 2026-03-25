#!/usr/bin/env node

const { spawnSync } = require('child_process');

function printHelp() {
  console.log(`Usage:
  node scripts/publish-dockerhub.js <version> [options]

Options:
  --username <name>     Docker Hub username (default: DOCKERHUB_USERNAME env)
  --image <name>        Image name (default: body-gen-comfyui)
  --platform <value>    Build platform (default: linux/amd64)
  --context <path>      Docker build context (default: .)
  --latest              Also tag and push :latest
  --no-login            Skip 'docker login'
  -h, --help            Show this help message

Examples:
  node scripts/publish-dockerhub.js v1 --username jeremytenjo
  DOCKERHUB_USERNAME=jeremytenjo node scripts/publish-dockerhub.js v1.1 --latest

If <version> or --username are not provided, the script will prompt for them.
`);
}

function run(cmd, args) {
  console.log(`\n$ ${cmd} ${args.join(' ')}`);
  const result = spawnSync(cmd, args, { stdio: 'inherit' });
  if (result.status !== 0) {
    process.exit(result.status || 1);
  }
}

function parseArgs(argv, config) {
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('-') && !config.version) {
      config.version = a;
      continue;
    }

    if (a === '--username') {
      config.username = argv[++i] || '';
    } else if (a === '--image') {
      config.image = argv[++i] || config.image;
    } else if (a === '--platform') {
      config.platform = argv[++i] || config.platform;
    } else if (a === '--context') {
      config.context = argv[++i] || config.context;
    } else if (a === '--latest') {
      config.latest = true;
    } else if (a === '--no-login') {
      config.login = false;
    } else {
      console.error(`Unknown argument: ${a}`);
      printHelp();
      process.exit(1);
    }
  }
}

async function promptForRequired(config) {
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
      validate(value) {
        if (!value || !String(value).trim()) {
          return 'Version is required';
        }
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
      validate(value) {
        if (!value || !String(value).trim()) {
          return 'Docker Hub username is required';
        }
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

async function main() {
  const argv = process.argv.slice(2);
  if (argv.includes('-h') || argv.includes('--help')) {
    printHelp();
    process.exit(0);
  }

  const config = {
    version: null,
    username: process.env.DOCKERHUB_USERNAME || '',
    image: 'body-gen-comfyui',
    platform: 'linux/amd64',
    context: '.',
    latest: false,
    login: true,
  };

  parseArgs(argv, config);
  await promptForRequired(config);

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
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
