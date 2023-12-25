ARG DEBIAN_RELEASE=bookworm
ARG LONG_VERSION
ARG TARGETARCH

FROM nerfd/rspamd:pkg-${TARGETARCH}-${LONG_VERSION} AS pkg
FROM --platform=linux/${TARGETARCH} debian:${DEBIAN_RELEASE}-slim AS install

ARG ASAN_TAG
ARG TARGETARCH
ENV ASAN_TAG=$ASAN_TAG
ENV TARGETARCH=$TARGETARCH

RUN	--mount=type=cache,from=pkg,source=/deb,target=/deb apt-get update \
	&& dpkg -i /deb/rspamd${ASAN_TAG}_*_${TARGETARCH}.deb /deb/rspamd${ASAN_TAG}-dbg_*_${TARGETARCH}.deb || true \
	&& apt-get install -f -y \
	&& apt-get -q clean \
	&& apt purge rspamd${ASAN_TAG} \
	&& rm -rf /var/cache/debconf /var/lib/apt/lists

RUN	--mount=type=cache,from=pkg,source=/deb,target=/deb apt-get update \
	&& dpkg -i /deb/rspamd${ASAN_TAG}_*_${TARGETARCH}.deb /deb/rspamd${ASAN_TAG}-dbg_*_${TARGETARCH}.deb \
	&& apt-get -q clean \
	&& rm -rf /var/cache/debconf /var/lib/apt/lists

COPY	lid.176.ftz /usr/share/rspamd/languages/fasttext_model.ftz

USER	11333:11333

VOLUME  [ "/var/lib/rspamd" ]

CMD     [ "/usr/bin/rspamd", "-f" ]

# https://www.rspamd.com/doc/workers
# 11332 proxy ; 11333 normal ; 11334 controller
EXPOSE  11332 11333 11334
