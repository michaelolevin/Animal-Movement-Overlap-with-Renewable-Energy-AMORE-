########################################################################################################################
# MoveApps R SDK
########################################################################################################################

FROM rocker/geospatial:4.5.1

LABEL org.opencontainers.image.authors="us@couchbits.com"
LABEL org.opencontainers.image.vendor="couchbits GmbH"

# --- CHANGE 1: install LaTeX packages as root, into the system-mode
# TinyTeX tree that ships with rocker/geospatial, BEFORE dropping to the
# non-root user below. Doing this after `USER $USER` (as previously)
# installed them in user mode against a sys-mode base install, which
# caused pdftex to fail at render time with:
#   "-user mode but path setup is -sys type, bailing out".
# Pre-build the pdftex/pdflatex format files here too, so the first
# render doesn't try to invoke mktexfmt at runtime as an unprivileged
# user (which is the immediate error we saw).
RUN R -e "tinytex::tlmgr_install(c( \
      'amsfonts', 'amsmath', 'booktabs', 'caption', 'float', \
      'hyperref', 'geometry', 'fancyhdr', 'xcolor', 'titling', \
      'parskip', 'setspace', 'enumitem', 'ulem' \
    ))"
RUN fmtutil-sys --all || true
# --- end CHANGE 1

# Security Aspects
# Create a non-root user
ARG username=moveapps
ARG uid=1001
ARG gid=staff
ENV USER=$username
ENV UID=$uid
ENV GID=$gid
ENV HOME=/home/$USER

RUN adduser --disabled-password \
    --gecos "Non-root user" \
    --uid $UID \
    --ingroup $GID \
    --home $HOME \
    $USER
RUN install -d -o moveapps -g staff $HOME/co-pilot-r
RUN install -d -o moveapps -g staff $HOME/.cache/R
USER $USER
WORKDIR $HOME/co-pilot-r

# Set renv environment variables
ENV RENV_PATHS_CACHE=$HOME/.cache/R/renv
ENV RENV_CONFIG_REPOS_OVERRIDE=https://cloud.r-project.org
ENV RENV_CONFIG_SANDBOX_ENABLED=FALSE

# Install renv if not available
RUN R -e "if (!requireNamespace('renv', quietly = TRUE)) install.packages('renv')"

# Copy renv files first (for better Docker layer caching)
COPY --chown=$UID:$GID renv.lock .Rprofile ./
COPY --chown=$UID:$GID renv/activate.R renv/settings.dcf ./renv/
# Restore packages
RUN R -e 'renv::restore(confirm = FALSE)'

# --- CHANGE 2: the previous tlmgr_install() block that lived here has
# been removed — it was running as $USER (see USER $USER above), which
# is what caused the sys/user mode mismatch. Moved to the top of the
# file, before the user is created/switched to.
# --- end CHANGE 2

# copy the app
# glob patterns to use conditional copy
COPY --chown=$UID:$GID sr[c]/ap[p]/* ./src/app/
COPY --chown=$UID:$GID data/ ./data/
COPY --chown=$UID:$GID sdk.R RFunction.R .env app-configuration.json start-process.sh ./

ENTRYPOINT ["/bin/bash"]