FROM vllm/vllm-openai:v0.17.0

# NIXL
RUN pip install nixl>=0.10.0

# LMCache (optional via build arg)
ARG INSTALL_LMCACHE=true
RUN if [ "$INSTALL_LMCACHE" = "true" ]; then \
      pip install lmcache>=0.0.5; \
    fi

# UCX/EFA libraries for multi-node
RUN apt-get update && apt-get install -y \
    libibverbs1 \
    librdmacm1 \
    libnuma1 \
    && rm -rf /var/lib/apt/lists/*

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
