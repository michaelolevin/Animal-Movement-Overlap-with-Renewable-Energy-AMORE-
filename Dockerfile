########################################################################################################################
# MoveApps R SDK
########################################################################################################################

FROM rocker/geospatial:4.5.1

LABEL org.opencontainers.image.authors="us@couchbits.com"
LABEL org.opencontainers.image.vendor="couchbits GmbH"

# Security Aspects
# Create a non-root user
ARG username=moveapps
ARG uid=1001
# group `staff` b/c of:
# When running rocker with a non-root user the docker user is still able to install packages.
# The user docker is member of the group staff and could write to /usr/local/lib/R/site-library.
# https://github.com/rocker-org/rocker/wiki/managing-users-in-docker
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
# create working dir with correct ownership
RUN install -d -o moveapps -g staff $HOME/co-pilot-r
# create cache-directory for renv with correct ownership
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

# LaTeX packages needed by the PDF report (data/auxiliary/.../report_template.Rmd).
# Must run as root: the base image's TeX Live is a *sys*-mode install
# (/usr/local/texlive, formats in /opt/texlive/texmf-var), which the non-root
# $USER cannot write to. `fmtutil-sys --all` pre-builds the pdftex/pdflatex
# format files here, so the first render doesn't try to invoke mktexfmt at
# runtime as an unprivileged user -- which fails with
#   "mktexfmt [ERROR]: -user mode but path setup is -sys type, bailing out."
#
# The repository is pinned to a frozen TeX Live 2025 snapshot rather than left
# to the image default. MoveApps builds this app on its own co-pilot-r base
# image, which does not carry rocker's tlmgr repo pin, so a bare
# `tlmgr install` there resolves to the live CTAN mirror -- now TeX Live 2026 --
# and aborts against this TL 2025 install with:
#   "tlmgr: Local TeX Live (2025) is older than remote repository (2026).
#    Cross release updates are only supported with update-tlmgr-latest"
USER root
RUN tlmgr install \
      --repository https://www.texlive.info/tlnet-archive/2025/10/30/tlnet \
      amsfonts amsmath booktabs caption \
      float hyperref geometry fancyhdr xcolor titling \
      parskip setspace enumitem ulem
RUN fmtutil-sys --all
USER $USER

# copy the app
# glob patterns to use conditional copy
COPY --chown=$UID:$GID sr[c]/ap[p]/* ./src/app/
COPY --chown=$UID:$GID data/ ./data/
COPY --chown=$UID:$GID sdk.R RFunction.R .env app-configuration.json start-process.sh ./

ENTRYPOINT ["/bin/bash"]