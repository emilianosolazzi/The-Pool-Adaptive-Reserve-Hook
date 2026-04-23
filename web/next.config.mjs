/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  webpack: (config) => {
    config.externals.push('pino-pretty', 'lokijs', 'encoding');
    // Optional deps some wallet SDKs reference only in RN/Node environments.
    config.resolve.fallback = {
      ...(config.resolve.fallback ?? {}),
      '@react-native-async-storage/async-storage': false,
    };
    return config;
  },
};

export default nextConfig;
