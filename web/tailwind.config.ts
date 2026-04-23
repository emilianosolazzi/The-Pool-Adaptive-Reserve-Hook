import type { Config } from 'tailwindcss';

const config: Config = {
  content: [
    './app/**/*.{ts,tsx}',
    './components/**/*.{ts,tsx}',
  ],
  theme: {
    extend: {
      fontFamily: {
        sans: ['var(--font-sans)', 'ui-sans-serif', 'system-ui'],
        mono: ['var(--font-mono)', 'ui-monospace', 'SFMono-Regular'],
      },
      colors: {
        ink: {
          950: '#05060a',
          900: '#0a0c14',
          800: '#111520',
          700: '#1a1f2e',
          600: '#252b3d',
        },
        accent: {
          400: '#7dd3fc',
          500: '#38bdf8',
          600: '#0ea5e9',
        },
        lime: {
          400: '#a3e635',
        },
      },
      backgroundImage: {
        'grid-fade':
          'radial-gradient(ellipse 80% 50% at 50% -20%, rgba(56,189,248,0.18), transparent)',
      },
      boxShadow: {
        glow: '0 0 60px -12px rgba(56,189,248,0.35)',
      },
    },
  },
  plugins: [],
};

export default config;
