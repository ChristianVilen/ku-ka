/** @type {import('tailwindcss').Config} */
export default {
	content: ["./src/**/*.{astro,html,js,ts}"],
	theme: {
		extend: {
			colors: {
				paper: {
					DEFAULT: "var(--color-paper)",
					2: "var(--color-paper-2)",
					3: "var(--color-paper-3)",
				},
				rule: {
					DEFAULT: "var(--color-rule)",
					2: "var(--color-rule-2)",
				},
				muted: "var(--color-muted)",
				neutral: "var(--color-neutral)",
				ink: {
					DEFAULT: "var(--color-ink)",
					2: "var(--color-ink-2)",
				},
				accent: {
					DEFAULT: "var(--color-accent)",
					hover: "var(--color-accent-hover)",
					ink: "var(--color-accent-ink)",
					bright: "var(--color-accent-bright)",
				},
				graphite: {
					DEFAULT: "var(--color-graphite)",
					2: "var(--color-graphite-2)",
					rule: "var(--color-graphite-rule)",
					ink: "var(--color-graphite-ink)",
					muted: "var(--color-graphite-muted)",
				},
			},
			fontFamily: {
				display: ['"Space Grotesk"', "ui-sans-serif", "system-ui", "sans-serif"],
				sans: ["Inter", "ui-sans-serif", "system-ui", "sans-serif"],
				mono: ['"JetBrains Mono"', "ui-monospace", "SFMono-Regular", "Menlo", "monospace"],
			},
		},
	},
	plugins: [],
};
