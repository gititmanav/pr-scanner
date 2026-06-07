FROM node:18-slim

# Install git (needed to clone repos)
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy scanner code and wrapper
COPY package.json package-lock.json ./
RUN npm ci --production

COPY scanner.js server.js scan-wrapper.js ./

# The wrapper is the entry point (one-shot task, not the HTTP server)
CMD ["node", "scan-wrapper.js"]
