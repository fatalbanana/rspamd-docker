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

local trigger_on(what_event) = {
  trigger: {
    event: {
      include: [
        what_event,
      ],
    },
  },
};

local rspamd_image = 'rspamd/rspamd';

local image_tags(asan_tag, arch) = [
  std.format('image%s-%s-${DRONE_SEMVER_SHORT}-${DRONE_SEMVER_BUILD}', [asan_tag, arch]),
];

local pkg_tags(arch) = [
  std.format('pkg-%s-${DRONE_SEMVER_SHORT}-${DRONE_SEMVER_BUILD}', arch),
];

local architecture_specific_pipeline(arch, get_image_tags=image_tags, get_pkg_tags=pkg_tags, rspamd_git='${DRONE_SEMVER_SHORT}', rspamd_version='${DRONE_SEMVER_SHORT}', long_version='${DRONE_SEMVER_SHORT}-${DRONE_SEMVER_BUILD}') = {
  local step_default_settings = {
    platform: 'linux/' + arch,
    repo: rspamd_image,
  },
  local install_step(name, asan_tag) = {
    name: name,
    depends_on: [
      'pkg_' + arch,
    ],
    image: 'rspamd/drone-docker-plugin',
    privileged: true,
    settings: {
      local asan_build_tag = if std.length(asan_tag) != 0 then ['ASAN_TAG=' + asan_tag] else [],
      dockerfile: 'Dockerfile',
      build_args: [
        'PKG_TAG=' + get_pkg_tags(arch)[0],
        'TARGETARCH=' + arch,
      ] + asan_build_tag,
      squash: true,
      tags: get_image_tags(asan_tag, arch),
      target: 'install',
    } + step_default_settings + docker_defaults,
  },
  name: 'rspamd_' + arch,
  platform: {
    os: 'linux',
    arch: arch,
  },
  steps: [
    {
      name: 'pkg_' + arch,
      image: 'rspamd/drone-docker-plugin',
      privileged: true,
      settings: {
        dockerfile: 'Dockerfile.pkg',
        build_args: [
          'RSPAMD_GIT=' + rspamd_git,
          'RSPAMD_VERSION=' + rspamd_version,
          'TARGETARCH=' + arch,
        ],
        tags: get_pkg_tags(arch),
        target: 'pkg',
      } + step_default_settings + docker_defaults,
    },
    install_step('install_' + arch, ''),
    install_step('install_asan_' + arch, '-asan'),
  ],
} + trigger_on('tag') + pipeline_defaults;

local multiarch_pipeline = {
  name: 'rspamd_multiarch',
  depends_on: [
    'rspamd_amd64',
    'rspamd_arm64',
  ],
  local multiarch_step(step_name, asan_tag) = {
    name: step_name,
    image: 'plugins/manifest',
    settings: {
      target: std.format('%s:image%s-${DRONE_SEMVER_SHORT}-${DRONE_SEMVER_BUILD}', [rspamd_image, asan_tag]),
      template: std.format('%s:image%s-ARCH-${DRONE_SEMVER_SHORT}-${DRONE_SEMVER_BUILD}', [rspamd_image, asan_tag]),
      platforms: [
        'linux/amd64',
        'linux/arm64',
      ],
    } + docker_defaults,
  },
  steps: [
    multiarch_step('multiarch_image', ''),
    multiarch_step('multiarch_asan_image', '-asan'),
  ],
} + trigger_on('tag') + pipeline_defaults;

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
        'bash -c "source $DRONE_WORKSPACE/venv/bin/activate && pip3 install --no-cache --disable-pip-version-check --no-binary :all: setuptools==57.5.0"',  // https://github.com/dmeranda/demjson/issues/43
        'bash -c "source $DRONE_WORKSPACE/venv/bin/activate && pip3 install --no-cache --disable-pip-version-check --no-binary :all: demjson psutil requests robotframework tornado"',
        'git clone -b ${DRONE_SEMVER_SHORT} https://github.com/rspamd/rspamd.git',
        'RSPAMD_INSTALLROOT=/usr bash -c "source $DRONE_WORKSPACE/venv/bin/activate && umask 0000 && robot --removekeywords wuks --exclude isbroken $DRONE_WORKSPACE/rspamd/test/functional/cases"',
      ],
    },
  ],
} + trigger_on('promote') + pipeline_defaults;

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
} + trigger_on('promote') + pipeline_defaults;

local cron_archspecific_splice = {
} + trigger_on('cron');

local cron_image_tags(asan_tag, arch) = [
  std.format('nightly%s-%s', [asan_tag, arch]),
];

local cron_pkg_tags(arch) = [
  std.format('pkg-%s-nightly', arch),
];

[
  architecture_specific_pipeline('amd64'),
  architecture_specific_pipeline('arm64'),
  architecture_specific_pipeline('amd64', cron_image_tags, cron_pkg_tags, 'master', '${DRONE_BUILD_CREATED}') + trigger_on('cron'),
  architecture_specific_pipeline('arm64', cron_image_tags, cron_pkg_tags, 'master', '${DRONE_BUILD_CREATED}') + trigger_on('cron'),
  multiarch_pipeline,
  prepromotion_test('amd64', ''),
  prepromotion_test('arm64', ''),
  promotion_multiarch('promotion_multiarch', 'promote_multiarch', ''),
  promotion_multiarch('promotion_multiarch_asan', 'promote_multiarch_asan', 'asan-'),
  {
    kind: 'signature',
    hmac: '0000000000000000000000000000000000000000000000000000000000000000',
  },
]
