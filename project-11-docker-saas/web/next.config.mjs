/** @type {import('next').NextConfig} */
const nextConfig = {
  // Emits .next/standalone with a minimal server.js + only the node_modules it needs
  output: "standalone",
  poweredByHeader: false,
  reactStrictMode: true,
};

export default nextConfig;
