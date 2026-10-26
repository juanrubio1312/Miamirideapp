const GRACE_PERIOD_MS = 14 * 24 * 60 * 60 * 1000;
const COMMISSION_RATE = 0.2;
const PASSENGER_PROMOTIONAL_RIDE_LIMIT = 3;
const PASSENGER_DISCOUNT_RATE = 0.4;
const PASSENGER_PAYMENT_METHODS = Object.freeze([
  'cash',
  'credit_card',
  'apple_pay',
  'google_pay',
]);

function isInGracePeriod(createdAt, now) {
  if (
    !(createdAt instanceof Date) ||
    !(now instanceof Date) ||
    !Number.isFinite(createdAt.getTime()) ||
    !Number.isFinite(now.getTime())
  ) {
    throw new TypeError('createdAt and now must be Date instances.');
  }
  const elapsedMs = now.getTime() - createdAt.getTime();
  return elapsedMs >= 0 && elapsedMs <= GRACE_PERIOD_MS;
}

function calculateCommissionCents(fare) {
  if (typeof fare !== 'number' || !Number.isFinite(fare) || fare <= 0) {
    throw new TypeError('fare must be a positive finite number.');
  }
  const fareCents = Math.round(fare * 100);
  return Math.round(fareCents * COMMISSION_RATE);
}

function calculatePassengerDiscountCents(fare) {
  if (typeof fare !== 'number' || !Number.isFinite(fare) || fare <= 0) {
    throw new TypeError('fare must be a positive finite number.');
  }
  const fareCents = Math.round(fare * 100);
  return Math.round(fareCents * PASSENGER_DISCOUNT_RATE);
}

module.exports = {
  COMMISSION_RATE,
  GRACE_PERIOD_MS,
  PASSENGER_DISCOUNT_RATE,
  PASSENGER_PROMOTIONAL_RIDE_LIMIT,
  PASSENGER_PAYMENT_METHODS,
  calculateCommissionCents,
  calculatePassengerDiscountCents,
  isInGracePeriod,
};
