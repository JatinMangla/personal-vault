/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,

  // Never ship source maps of the crypto code to production clients.
  productionBrowserSourceMaps: false,

  // Security headers are also set in vercel.json; defining them here means they
  // apply to `next start` and local development too, so a header regression
  // shows up before deploy rather than after.
  async headers() {
    return [
      {
        source: '/:path*',
        headers: [
          { key: 'X-Content-Type-Options', value: 'nosniff' },
          { key: 'X-Frame-Options', value: 'DENY' },
          { key: 'Referrer-Policy', value: 'no-referrer' },
          { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=(), interest-cohort=()' },
        ],
      },
    ];
  },
};

export default nextConfig;
