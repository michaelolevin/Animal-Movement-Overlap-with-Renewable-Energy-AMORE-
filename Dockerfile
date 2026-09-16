########################################################################################################################
# MoveApps R SDK
########################################################################################################################

FROM rocker/geospatial:4.6.1

LABEL org.opencontainers.image.authors="us@couchbits.com"
LABEL org.opencontainers.image.vendor="couchbits GmbH"

RUN apt-get update && apt-get install -y --no-install-recommends \
# rocker dropped cmake from `geospatial` in 4.5.3. Packages that build a vendored C++ dependency
# need it -- e.g. s2 builds Abseil with it, and without s2 neither sf nor move2 install.
    cmake \
# clean-up
    && apt-get clean

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

# LaTeX for the PDF report (data/auxiliary/.../report_template.Rmd, rendered
# with rmarkdown::pdf_document).
#
# rocker/geospatial >= 4.6.0 ships no TeX Live any more, so we install TinyTeX
# (the R Markdown-oriented TeX Live distribution) from the current release.
#
# On MoveApps this block is executed as root, in the platform's own base image,
# BEFORE `renv::restore()` has run -- so it must not rely on any R package from
# renv.lock (e.g. `tinytex::install_tinytex()` fails there with "no package
# called 'tinytex'"), nor on a particular user, HOME or ENV. It therefore
# unpacks the prebuilt TinyTeX bundle (what yihui.org/tinytex/install-bin-unix.sh
# downloads; linux/amd64, which is what MoveApps builds) system-wide into
# /opt/TinyTeX and symlinks the binaries into /usr/local/bin so pdflatex/tlmgr
# are on everyone's PATH. The tree is made world-writable (as rocker does for its own TeX Live)
# so the non-root app user can regenerate formats or font maps at runtime.
#
# TinyTeX-1 already covers what pandoc's default LaTeX template needs; the extra
# packages are the ones the report and knitr::kable tables pull in beyond that.
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends perl xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL https://github.com/rstudio/tinytex-releases/releases/download/daily/TinyTeX-1-linux-x86_64.tar.xz \
       | tar -xJ -C /opt \
    && mv /opt/.TinyTeX /opt/TinyTeX \
    && /opt/TinyTeX/bin/*/tlmgr option sys_bin /usr/local/bin \
    && /opt/TinyTeX/bin/*/tlmgr postaction install script xetex \
    && /opt/TinyTeX/bin/*/tlmgr path add \
    && tlmgr install \
         booktabs caption multirow float setspace parskip \
         microtype upquote xurl footnotehyper bookmark \
         fancyhdr titling enumitem ulem \
    && chmod -R a+rwX /opt/TinyTeX
USER $USER

# copy the app
# glob patterns to use conditional copy
COPY --chown=$UID:$GID sr[c]/ap[p]/* ./src/app/
COPY --chown=$UID:$GID data/ ./data/
COPY --chown=$UID:$GID sdk.R RFunction.R .env app-configuration.json start-process.sh ./

ENTRYPOINT ["/bin/bash"]
