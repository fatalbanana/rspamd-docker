local docker_defaults = {
  username: {
    from_secret: 'docker_username',
  },
  password: {
    from_secret: 'docker_password',
  },
};

local pipeline_defaults = {
  kind: 'pipeline',
  type: 'docker',
};

local trigger_on_tag = {
  trigger: {
    event: {
      include: [
        'tag',
      ],
    },
  },
};

local trigger_on_promotion = {
  trigger: {
    event: [
      'promote',
    ],
  },
};

local rspamd_image = 'nerfd/rspamd';

local multiarch_pipeline(architectures) = {
  local step_default_settings = {
    platform: architectures,
    repo: rspamd_image,
  },
  local install_step(name, asan_tag) = {
    name: name,
    depends_on: [
      'pkg_amd64',
      'pkg_arm64',
    ],
    privileged: true,
    image: 'woodpeckerci/plugin-docker-buildx:2',
    settings: {
      local asan_build_tag = if std.length(asan_tag) != 0 then ['ASAN_TAG=' + asan_tag] else [],
      dockerfile: 'Dockerfile',
      build_args: [
        'LONG_VERSION=${DRONE_SEMVER_SHORT}-${DRONE_SEMVER_BUILD}',
      ] + asan_build_tag,
      squash: true,
      tags: [
        std.format('image%s-${DRONE_SEMVER_SHORT}-${DRONE_SEMVER_BUILD}', [asan_tag]),
      ],
      target: 'install',
    } + step_default_settings + docker_defaults,
  },
  name: 'rspamd_multiarch',
  platform: {
    os: 'linux',
    arch: architectures,
  },
  steps: [
    {
      name: 'pkg_multiarch',
      privileged: true,
      image: 'woodpeckerci/plugin-docker-buildx:2',
      settings: {
        dockerfile: 'Dockerfile.pkg',
        build_args: [
          'RSPAMD_VERSION=${DRONE_SEMVER_SHORT}',
        ],
        tags: [
          'pkg-${DRONE_SEMVER_SHORT}-${DRONE_SEMVER_BUILD}',
        ],
        target: 'pkg',
      } + step_default_settings + docker_defaults,
    },
    install_step('install_multiarch', ''),
    install_step('install_asan_multiarch', '-asan'),
  ],
} + trigger_on_tag + pipeline_defaults;

local prepromotion_test(arch, asan_tag) = {
  name: 'prepromo_' + arch,
  platform: {
    os: 'linux',
    arch: arch,
  },
  steps: [
    {
      name: 'pre_promotion_test',
      image: std.format('%s:image-%s%s-${DRONE_SEMVER_SHORT}-${DRONE_SEMVER_BUILD}', [rspamd_image, arch, asan_tag]),
      user: 'root',
      commands: [
        'apt-get update',
        'apt-get install -y git miltertest python3 python3-dev python3-pip python3-venv redis-server',
        'python3 -mvenv $DRONE_WORKSPACE/venv',
        'bash -c "source $DRONE_WORKSPACE/venv/bin/activate && pip3 install --no-cache --disable-pip-version-check --no-binary :all: setuptools==57.5.0"', # https://github.com/dmeranda/demjson/issues/43
        'bash -c "source $DRONE_WORKSPACE/venv/bin/activate && pip3 install --no-cache --disable-pip-version-check --no-binary :all: demjson psutil requests robotframework tornado"',
        'git clone -b ${DRONE_SEMVER_SHORT} https://github.com/rspamd/rspamd.git',
        'RSPAMD_INSTALLROOT=/usr bash -c "source $DRONE_WORKSPACE/venv/bin/activate && umask 0000 && robot --removekeywords wuks --exclude isbroken $DRONE_WORKSPACE/rspamd/test/functional/cases"',
      ],
    },
  ],
} + trigger_on_promotion + pipeline_defaults;

local promotion_multiarch(name, step_name, asan_tag) = {
  depends_on: [
    'prepromo_amd64',
    'prepromo_arm64',
  ],
  name: name,
  steps: [
    {
      name: step_name,
      image: 'plugins/manifest',
      settings: {
        target: std.format('%s:%s${DRONE_SEMVER_SHORT}', [rspamd_image, asan_tag]),
        template: std.format('%s:image-%sARCH-${DRONE_SEMVER_SHORT}-${DRONE_SEMVER_BUILD}', [rspamd_image, asan_tag]),
        platforms: [
          'linux/amd64',
          'linux/arm64',
        ],
        tags: [
          asan_tag + 'latest',
          asan_tag + '${DRONE_SEMVER_MAJOR}.${DRONE_SEMVER_MINOR}',
        ],
      } + docker_defaults,
    },
  ],
} + trigger_on_promotion + pipeline_defaults;

[
  multiarch_pipeline(['linux/amd64', 'linux/arm64']),
  prepromotion_test('amd64', ''),
  prepromotion_test('arm64', ''),
  promotion_multiarch('promotion_multiarch', 'promote_multiarch', ''),
  promotion_multiarch('promotion_multiarch_asan', 'promote_multiarch_asan', 'asan-'),
  {
    kind: 'signature',
    hmac: '0000000000000000000000000000000000000000000000000000000000000000',
  },
]
