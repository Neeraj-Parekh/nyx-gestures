export default [
  {
    files: ['**/*.js'],
    languageOptions: {
      ecmaVersion: 2024,
      sourceType: 'module',
      // GJS provides these; node's bare ES2024 global set does not.
      // TextEncoder/TextDecoder were verified inside a live GNOME 50 headless
      // shell (typeof === 'function', and encode('hi').length === 2) before
      // being declared here, rather than assumed.
      globals: {
        global: 'readonly',
        log: 'readonly',
        console: 'readonly',
        textEncoding: 'readonly',
        imports: 'readonly',
        TextEncoder: 'readonly',
        TextDecoder: 'readonly',
      },
    },
    rules: {
      'no-undef': 'error',
      'no-unused-vars': ['warn', { args: 'none' }],
      'no-redeclare': 'error',
      'no-dupe-keys': 'error',
      'no-const-assign': 'error',
      'no-fallthrough': 'error',
      'no-self-assign': 'error',
      'no-cond-assign': 'error',
      'no-constant-condition': 'warn',
    },
  },
];