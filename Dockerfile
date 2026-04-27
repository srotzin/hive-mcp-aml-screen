FROM node:20-alpine
WORKDIR /app
RUN apk add --no-cache python3 make g++ sqlite
COPY package.json ./
RUN npm install --omit=dev
COPY . .
ENV NODE_ENV=production
ENV PORT=3000
EXPOSE 3000
CMD ["node", "server.js"]
