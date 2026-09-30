import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    // The app is Swift; `swift test --package-path BBIconPackage` is its
    // suite. What is left here is the build tooling under scripts/, which is
    // plain .mjs and never compiled into anything. It still gets tested.
    include: ["scripts/**/*.test.mjs"],
    testTimeout: 30_000,
  },
});
