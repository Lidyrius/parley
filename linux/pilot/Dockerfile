# Parley server-host pilot: one throwaway container, nothing installed on the host.
# .NET SDK (builds linux/ and cross-checks windows/), Claude Code prerequisites, tmux,
# Node (Playwright MCP), Google Chrome on a virtual display.
FROM mcr.microsoft.com/dotnet/sdk:8.0

ENV DEBIAN_FRONTEND=noninteractive TZ=Europe/Berlin LANG=de_DE.UTF-8 LC_ALL=de_DE.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git tmux jq perl procps less locales tzdata xz-utils unzip \
      openssh-client rsync xvfb xauth x11-utils imagemagick fonts-liberation \
      fonts-noto-color-emoji socat bubblewrap ripgrep \
 && sed -i 's/^# *de_DE.UTF-8/de_DE.UTF-8/; s/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen \
 && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone \
 && curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o /tmp/chrome.deb \
 && apt-get install -y --no-install-recommends /tmp/chrome.deb && rm /tmp/chrome.deb \
 && curl -fsSL https://nodejs.org/dist/v22.11.0/node-v22.11.0-linux-x64.tar.xz | tar -xJ -C /usr/local --strip-components=1 \
 && rm -rf /var/lib/apt/lists/*

# Same home path as on the Mac, so Claude Code's project keys and cwd-based addressing match.
RUN groupadd -g 1500 sydney && useradd -d /Users/sydney -u 1500 -g 1500 -s /bin/bash sydney \
 && mkdir -p /Users/sydney && chown 1500:1500 /Users/sydney

USER sydney
WORKDIR /Users/sydney
ENV PATH=/Users/sydney/.local/bin:/usr/local/bin:/usr/bin:/bin DISPLAY=:99
CMD ["sleep", "infinity"]
