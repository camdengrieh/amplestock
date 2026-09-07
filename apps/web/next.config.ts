// SPDX-License-Identifier: MIT
import type {NextConfig} from 'next'

/**
 * The build must succeed with no network access (CI runs it offline after `pnpm install`), so:
 * no remote fonts, no remote images, no telemetry, and every asset is local. `reactStrictMode`
 * stays on because the write hooks are effectful and double-invocation is exactly the bug class
 * a transaction surface must not have.
 */
const nextConfig: NextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  images: {unoptimized: true},
  // `@amplestocks/abis` ships raw TypeScript (its `main` points at `src/index.ts`), so the bundler
  // has to compile it rather than treat it as a prebuilt dependency.
  transpilePackages: ['@amplestocks/abis'],
  // The wallet stack ships browser globals that a server bundle must not try to resolve.
  serverExternalPackages: ['@reown/appkit', '@reown/appkit-adapter-wagmi'],
  typescript: {ignoreBuildErrors: false},
}

export default nextConfig
