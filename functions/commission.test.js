const assert = require('node:assert/strict');
const test = require('node:test');

const {
  GRACE_PERIOD_MS,
  calculateCommissionCents,
  calculatePassengerDiscountCents,
  isInGracePeriod,
} = require('./commission');

test('includes the exact 14-day grace-period boundary', () => {
  const createdAt = new Date('2026-01-01T00:00:00.000Z');
  const deadline = new Date(createdAt.getTime() + GRACE_PERIOD_MS);

  assert.equal(isInGracePeriod(createdAt, deadline), true);
  assert.equal(
    isInGracePeriod(createdAt, new Date(deadline.getTime() + 1)),
    false,
  );
});

test('does not grant the grace period for a future registration date', () => {
  const now = new Date('2026-01-01T00:00:00.000Z');

  assert.equal(
    isInGracePeriod(new Date(now.getTime() + 1), now),
    false,
  );
});

test('calculates 20 percent commission in cents', () => {
  assert.equal(calculateCommissionCents(25), 500);
  assert.equal(calculateCommissionCents(12.34), 247);
});

test('calculates the 40 percent passenger discount in cents', () => {
  assert.equal(calculatePassengerDiscountCents(25), 1000);
  assert.equal(calculatePassengerDiscountCents(12.34), 494);
});
