const test = require('node:test');
const assert = require('node:assert');
const { greet } = require('../src/greet');

test('greets the world by default', () => {
  assert.strictEqual(greet(), 'Hello, world!');
});

test('greets a given name', () => {
  assert.strictEqual(greet('Ada'), 'Hello, Ada!');
});
