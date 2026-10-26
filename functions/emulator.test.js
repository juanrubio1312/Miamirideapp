const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const test = require('node:test');

const { initializeApp, deleteApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { getFirestore } = require('firebase-admin/firestore');

const projectId = process.env.GCLOUD_PROJECT || 'miamirideapp';
const firestoreHost = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8080';
const authHost = process.env.FIREBASE_AUTH_EMULATOR_HOST || '127.0.0.1:9099';
const functionsHost = '127.0.0.1:5001';

process.env.FIRESTORE_EMULATOR_HOST = firestoreHost;
process.env.FIREBASE_AUTH_EMULATOR_HOST = authHost;

const adminApp = initializeApp({ projectId }, `commission-test-${randomUUID()}`);
const firestore = getFirestore(adminApp);

async function createAuthUser() {
  const email = `${randomUUID()}@example.test`;
  const authResponse = await fetch(
    `http://${authHost}/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake-api-key`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email,
        password: 'test-password-123',
        returnSecureToken: true,
      }),
    },
  );
  const authPayload = await authResponse.json();
  assert.equal(authResponse.ok, true, JSON.stringify(authPayload));
  const { localId, idToken } = authPayload;

  return { uid: localId, idToken };
}

async function createAdminToken(user) {
  const customToken = await getAuth(adminApp).createCustomToken(user.uid, {
    admin: true,
  });
  const response = await fetch(
    `http://${authHost}/identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=fake-api-key`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token: customToken, returnSecureToken: true }),
    },
  );
  const payload = await response.json();
  assert.equal(response.ok, true, JSON.stringify(payload));
  return { ...user, idToken: payload.idToken };
}

async function createDriver(createdAt) {
  const user = await createAuthUser();
  await firestore.collection('users').doc(user.uid).set({
    role: 'driver',
    driverApproved: true,
    createdAt,
    saldoBilletera: 0,
  });

  return user;
}

async function requestDriverApproval(
  user,
  nombre,
  numeroDocumento,
  vehicleYear = new Date().getFullYear(),
) {
  return invokeCallable('solicitarAltaConductor', user, {
    nombre,
    numeroDocumento,
    vehicleYear,
  });
}

async function finishRide(driver, rideId) {
  const response = await fetch(
    `http://${functionsHost}/${projectId}/us-central1/finalizarViaje`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${driver.idToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ data: { tripId: rideId } }),
    },
  );
  const payload = await response.json();
  assert.equal(response.ok, true, JSON.stringify(payload));
  return payload.result;
}

async function createPassenger({ completedRidesCount } = {}) {
  const user = await createAuthUser();
  await firestore.collection('users').doc(user.uid).set({
    role: 'passenger',
    nombre: 'Test Passenger',
    ...(completedRidesCount == null ? {} : { completedRidesCount }),
  });
  return user;
}

async function invokeCallable(name, user, data = {}) {
  const response = await fetch(
    `http://${functionsHost}/${projectId}/us-central1/${name}`,
    {
      method: 'POST',
      headers: {
        Authorization: ['Bearer', user.idToken].join(' '),
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ data }),
    },
  );
  return { response, payload: await response.json() };
}

async function requestRide(passenger, paymentMethod = 'cash') {
  return invokeCallable('crearSolicitudViaje', passenger, {
    origen: 'Origin',
    destino: 'Destination',
    tarifa: 25,
    ...(paymentMethod == null ? {} : { paymentMethod }),
  });
}

async function getReferralInfo(passenger) {
  return invokeCallable('obtenerEstadoReferidos', passenger);
}

async function createActiveRide(driver, tarifa) {
  const passenger = await createPassenger({ completedRidesCount: 3 });
  const rideRef = firestore.collection('rides').doc();
  await rideRef.set({
    estado: 'EN_CURSO',
    conductorUid: driver.uid,
    pasajeroUid: passenger.uid,
    tarifa,
    paymentMethod: 'cash',
  });
  return rideRef;
}

test('generates a stable unique passenger referral code', async () => {
  const passenger = await createPassenger();
  const firstResult = await getReferralInfo(passenger);
  assert.equal(firstResult.response.ok, true, JSON.stringify(firstResult.payload));
  const code = firstResult.payload.result.referralCode;
  assert.match(code, /^RUNS-[A-F0-9]{8}$/);
  const codeDocument = await firestore
    .collection('referralCodes')
    .doc(code)
    .get();
  assert.equal(codeDocument.data().ownerUid, passenger.uid);
  assert.equal(codeDocument.data().referredUid, null);
  assert.equal(firstResult.payload.result.referralCodeUsed, false);
  assert.equal(
    (
      await firestore.collection('referralAccounts').doc(passenger.uid).get()
    ).data().referralCode,
    code,
  );
  const privateAccountResponse = await fetch(
    `http://${firestoreHost}/v1/projects/${projectId}/databases/(default)/documents/referralAccounts/${passenger.uid}`,
    {
      headers: { Authorization: `Bearer ${passenger.idToken}` },
    },
  );
  assert.equal(privateAccountResponse.status, 403);

  const repeatedResult = await getReferralInfo(passenger);
  assert.equal(repeatedResult.response.ok, true);
  assert.equal(repeatedResult.payload.result.referralCode, code);
});

test('applies each referral code once and rejects self-referrals', async () => {
  const inviter = await createPassenger();
  const referralInfo = await getReferralInfo(inviter);
  const code = referralInfo.payload.result.referralCode;
  const invitee = await createPassenger();

  const applyResult = await invokeCallable(
    'aplicarCodigoInvitacion',
    invitee,
    { code: code.toLowerCase() },
  );
  assert.equal(applyResult.response.ok, true, JSON.stringify(applyResult.payload));
  assert.equal(applyResult.payload.result.applied, true);

  const repeatedResult = await invokeCallable(
    'aplicarCodigoInvitacion',
    invitee,
    { code },
  );
  assert.equal(repeatedResult.response.ok, true);
  assert.equal(repeatedResult.payload.result.alreadyApplied, true);
  const inviterStateAfterUse = await getReferralInfo(inviter);
  assert.equal(inviterStateAfterUse.payload.result.referralCodeUsed, true);

  const secondInvitee = await createPassenger();
  const reusedResult = await invokeCallable(
    'aplicarCodigoInvitacion',
    secondInvitee,
    { code },
  );
  assert.equal(reusedResult.response.ok, false);
  assert.match(reusedResult.payload.error.message, /ya fue utilizado/i);

  const selfReferral = await invokeCallable(
    'aplicarCodigoInvitacion',
    inviter,
    { code },
  );
  assert.equal(selfReferral.response.ok, false);
  assert.match(selfReferral.payload.error.message, /propio código/i);

  const unusedInviter = await createPassenger();
  const unusedCode = (await getReferralInfo(unusedInviter))
    .payload.result.referralCode;
  const passengerWithCompletedTrip = await createPassenger({
    completedRidesCount: 1,
  });
  const lateApplyResult = await invokeCallable(
    'aplicarCodigoInvitacion',
    passengerWithCompletedTrip,
    { code: unusedCode },
  );
  assert.equal(lateApplyResult.response.ok, false);
  assert.match(lateApplyResult.payload.error.message, /antes de completar/i);
});

test('credits both passengers once after the invited passenger completes a trip', async () => {
  const inviter = await createPassenger();
  const referralInfo = await getReferralInfo(inviter);
  const invitee = await createPassenger();
  const applyResult = await invokeCallable(
    'aplicarCodigoInvitacion',
    invitee,
    { code: referralInfo.payload.result.referralCode },
  );
  assert.equal(applyResult.response.ok, true, JSON.stringify(applyResult.payload));

  const driver = await createDriver(
    new Date(Date.now() - 15 * 24 * 60 * 60 * 1000),
  );
  const rideRef = firestore.collection('rides').doc();
  await rideRef.set({
    estado: 'EN_CURSO',
    conductorUid: driver.uid,
    pasajeroUid: invitee.uid,
    tarifa: 25,
    paymentMethod: 'cash',
  });

  const result = await finishRide(driver, rideRef.id);
  const [inviterAccount, inviteeAccount, reward] = await Promise.all([
    firestore.collection('referralAccounts').doc(inviter.uid).get(),
    firestore.collection('referralAccounts').doc(invitee.uid).get(),
    firestore
      .collection('referralRewardTransactions')
      .doc(invitee.uid)
      .get(),
  ]);
  assert.equal(result.referralRewardAmount, 10);
  assert.equal(inviterAccount.data().referralCreditBalance, 10);
  assert.equal(inviteeAccount.data().referralCreditBalance, 10);
  assert.equal(inviteeAccount.data().referralRewardGranted, true);
  assert.equal(reward.data().inviterUid, inviter.uid);
  assert.equal(reward.data().invitedUid, invitee.uid);
  assert.equal(reward.data().amount, 10);
  assert.equal(reward.data().tripId, rideRef.id);

  const retryResult = await finishRide(driver, rideRef.id);
  assert.equal(retryResult.referralRewardAmount, 10);
  const nextRideRef = firestore.collection('rides').doc();
  await nextRideRef.set({
    estado: 'EN_CURSO',
    conductorUid: driver.uid,
    pasajeroUid: invitee.uid,
    tarifa: 30,
    paymentMethod: 'cash',
  });
  const nextRideResult = await finishRide(driver, nextRideRef.id);
  const [inviterAfterNextRide, inviteeAfterNextRide] = await Promise.all([
    firestore.collection('referralAccounts').doc(inviter.uid).get(),
    firestore.collection('referralAccounts').doc(invitee.uid).get(),
  ]);
  assert.equal(nextRideResult.referralRewardAmount, 0);
  assert.equal(inviterAfterNextRide.data().referralCreditBalance, 10);
  assert.equal(inviteeAfterNextRide.data().referralCreditBalance, 10);
});

test('waives commission during grace period and writes zero commission', async () => {
  const driver = await createDriver(
    new Date(Date.now() - 24 * 60 * 60 * 1000),
  );
  const rideRef = await createActiveRide(driver, 50);

  const result = await finishRide(driver, rideRef.id);
  const [ride, profile, ledger] = await Promise.all([
    rideRef.get(),
    firestore.collection('users').doc(driver.uid).get(),
    firestore.collection('commissionTransactions').doc(rideRef.id).get(),
  ]);

  assert.equal(result.commissionWaived, true);
  assert.equal(result.commissionAmount, 0);
  assert.equal(ride.data().estado, 'FINALIZADO');
  assert.equal(ride.data().commissionAmount, 0);
  assert.equal(profile.data().saldoBilletera, 0);
  assert.equal(ledger.data().commissionAmount, 0);
});

test('charges 20 percent after grace period and does not charge twice', async () => {
  const driver = await createDriver(
    new Date(Date.now() - 15 * 24 * 60 * 60 * 1000),
  );
  const rideRef = await createActiveRide(driver, 25);

  const firstResult = await finishRide(driver, rideRef.id);
  const repeatedResult = await finishRide(driver, rideRef.id);
  const profile = await firestore.collection('users').doc(driver.uid).get();

  assert.equal(firstResult.commissionWaived, false);
  assert.equal(firstResult.commissionAmount, 5);
  assert.equal(repeatedResult.commissionAmount, 5);
  assert.equal(profile.data().saldoBilletera, -5);
});

test('rejects client-created profiles with a backdated createdAt', async () => {
  const user = await createAuthUser();
  const response = await fetch(
    `http://${firestoreHost}/v1/projects/${projectId}/databases/(default)/documents/users/${user.uid}?currentDocument.exists=false`,
    {
      method: 'PATCH',
      headers: {
        Authorization: `Bearer ${user.idToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        fields: {
          role: { stringValue: 'driver' },
          saldoBilletera: { doubleValue: 0 },
          createdAt: {
            timestampValue: new Date(Date.now() - 30 * 24 * 60 * 60 * 1000)
              .toISOString(),
          },
        },
      }),
    },
  );

  assert.equal(response.status, 403, await response.text());
});

test('driver registration creates a pending application, not a driver profile', async () => {
  const user = await createAuthUser();
  const { response, payload } = await requestDriverApproval(
    user,
    'Test Driver',
    `document-${randomUUID()}`,
  );

  assert.equal(response.ok, true, JSON.stringify(payload));
  assert.equal(payload.result.status, 'pending');
  const [profile, application] = await Promise.all([
    firestore.collection('users').doc(user.uid).get(),
    firestore.collection('driverApplications').doc(user.uid).get(),
  ]);
  assert.equal(profile.data().role, 'pending_driver');
  assert.equal(profile.data().driverApproved, false);
  assert.equal(profile.data().vehicleYear, new Date().getFullYear());
  assert.equal(application.data().status, 'pending');
  assert.equal(application.data().vehicleYear, new Date().getFullYear());

  const directRead = await fetch(
    `http://${firestoreHost}/v1/projects/${projectId}/databases/(default)/documents/driverApplications/${user.uid}`,
    { headers: { Authorization: ['Bearer', user.idToken].join(' ') } },
  );
  assert.equal(directRead.status, 403, await directRead.text());
});

test('rejects missing, old, non-integer, and future vehicle years', async () => {
  for (const [label, vehicleYear] of [
    ['missing', undefined],
    ['too old', 2013],
    ['non-integer', 2020.5],
    ['future', new Date().getFullYear() + 1],
  ]) {
    const user = await createAuthUser();
    const response = await invokeCallable(
      'solicitarAltaConductor',
      user,
      {
        nombre: 'Test Driver',
        numeroDocumento: `document-${randomUUID()}`,
        ...(vehicleYear === undefined ? {} : { vehicleYear }),
      },
    );
    assert.equal(response.response.ok, false, label);
    assert.equal(response.payload.error.status, 'INVALID_ARGUMENT', label);
    assert.equal(
      (await firestore.collection('users').doc(user.uid).get()).exists,
      false,
      label,
    );
  }
});

test('rejects duplicate driver documents and non-admin application reviews', async () => {
  const firstUser = await createAuthUser();
  const documentNumber = `document-${randomUUID()}`;
  const firstRequest = await requestDriverApproval(
    firstUser,
    'First Driver',
    documentNumber,
  );
  assert.equal(firstRequest.response.ok, true, JSON.stringify(firstRequest.payload));

  const duplicateUser = await createAuthUser();
  const duplicateRequest = await requestDriverApproval(
    duplicateUser,
    'Second Driver',
    documentNumber,
  );
  assert.equal(duplicateRequest.response.ok, false);
  assert.equal(duplicateRequest.payload.error.status, 'ALREADY_EXISTS');

  const review = await invokeCallable('revisarSolicitudConductor', firstUser, {
    uid: firstUser.uid,
    decision: 'approved',
  });
  assert.equal(review.response.ok, false);
  assert.equal(review.payload.error.status, 'PERMISSION_DENIED');
});

test('an administrator can approve a pending driver application', async () => {
  const user = await createAuthUser();
  const registration = await requestDriverApproval(
    user,
    'Approved Driver',
    `document-${randomUUID()}`,
  );
  assert.equal(registration.response.ok, true, JSON.stringify(registration.payload));

  const admin = await createAuthUser();
  const adminWithClaim = await createAdminToken(admin);
  const review = await invokeCallable(
    'revisarSolicitudConductor',
    adminWithClaim,
    { uid: user.uid, decision: 'approved' },
  );

  assert.equal(review.response.ok, true, JSON.stringify(review.payload));
  assert.equal(review.payload.result.status, 'approved');
  const [profile, application] = await Promise.all([
    firestore.collection('users').doc(user.uid).get(),
    firestore.collection('driverApplications').doc(user.uid).get(),
  ]);
  assert.equal(profile.data().role, 'driver');
  assert.equal(profile.data().driverApproved, true);
  assert.equal(typeof profile.data().createdAt.toDate, 'function');
  assert.equal(application.data().status, 'approved');
  assert.equal(application.data().reviewedBy, admin.uid);
});

test('refuses ride completion for drivers without trusted approval', async () => {
  const unapprovedDriver = await createAuthUser();
  await firestore.collection('users').doc(unapprovedDriver.uid).set({
    role: 'driver',
    createdAt: new Date(Date.now() - 15 * 24 * 60 * 60 * 1000),
    saldoBilletera: 0,
  });
  const rideRef = await createActiveRide(unapprovedDriver, 25);

  const result = await invokeCallable(
    'finalizarViaje',
    unapprovedDriver,
    { tripId: rideRef.id },
  );

  assert.equal(result.response.ok, false);
  assert.equal(result.payload.error.status, 'PERMISSION_DENIED');
});

test('rejects client-created driver profiles', async () => {
  const user = await createAuthUser();
  const response = await fetch(
    `http://${firestoreHost}/v1/projects/${projectId}/databases/(default)/documents/users/${user.uid}?currentDocument.exists=false`,
    {
      method: 'PATCH',
      headers: {
        Authorization: ['Bearer', user.idToken].join(' '),
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        fields: {
          uid: { stringValue: user.uid },
          role: { stringValue: 'driver' },
          driverApproved: { booleanValue: true },
          createdAt: { timestampValue: new Date().toISOString() },
        },
      }),
    },
  );

  assert.equal(response.status, 403, await response.text());
});

test('prevents passengers from creating rides or changing the completed counter', async () => {
  const passenger = await createPassenger();
  const rideResponse = await fetch(
    `http://${firestoreHost}/v1/projects/${projectId}/databases/(default)/documents/rides/${randomUUID()}?currentDocument.exists=false`,
    {
      method: 'PATCH',
      headers: {
        Authorization: ['Bearer', passenger.idToken].join(' '),
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        fields: {
          pasajeroUid: { stringValue: passenger.uid },
          origen: { stringValue: 'Origin' },
          destino: { stringValue: 'Destination' },
          tarifa: { doubleValue: 25 },
          estado: { stringValue: 'BUSCANDO' },
        },
      }),
    },
  );
  assert.equal(rideResponse.status, 403, await rideResponse.text());

  const profileResponse = await fetch(
    `http://${firestoreHost}/v1/projects/${projectId}/databases/(default)/documents/users/${passenger.uid}?updateMask.fieldPaths=completedRidesCount`,
    {
      method: 'PATCH',
      headers: {
        Authorization: ['Bearer', passenger.idToken].join(' '),
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        fields: { completedRidesCount: { integerValue: '3' } },
      }),
    },
  );
  assert.equal(profileResponse.status, 403, await profileResponse.text());
});

test('counts legacy finalized rides when the passenger counter is not initialized', async () => {
  const passenger = await createPassenger();
  await Promise.all(
    ['legacy-ride-1', 'legacy-ride-2'].map((rideId) =>
      firestore.collection('rides').doc(rideId).set({
        pasajeroUid: passenger.uid,
        estado: 'FINALIZADO',
      }),
    ),
  );

  const { response, payload } = await invokeCallable(
    'contarViajesFinalizados',
    passenger,
  );
  assert.equal(response.ok, true, JSON.stringify(payload));
  assert.equal(payload.result.completedRideCount, 2);
  assert.equal(payload.result.discountedRidesRemaining, 1);
});

test('applies a 40 percent passenger discount and subsidizes the driver', async () => {
  const passenger = await createPassenger();
  const driver = await createDriver(
    new Date(Date.now() - 15 * 24 * 60 * 60 * 1000),
  );
  const { response, payload } = await requestRide(passenger);
  assert.equal(response.ok, true, JSON.stringify(payload));
  const rideRef = firestore.collection('rides').doc(payload.result.tripId);
  const requestedRide = await rideRef.get();
  assert.equal(requestedRide.data().passengerDiscountRate, 0.4);
  assert.equal(requestedRide.data().passengerDiscountAmount, 10);
  assert.equal(requestedRide.data().passengerAmountDue, 15);
  await rideRef.update({
    estado: 'EN_CURSO',
    conductorUid: driver.uid,
  });

  const result = await finishRide(driver, rideRef.id);
  const [ride, passengerProfile, driverProfile, subsidy] = await Promise.all([
    rideRef.get(),
    firestore.collection('users').doc(passenger.uid).get(),
    firestore.collection('users').doc(driver.uid).get(),
    firestore
      .collection('passengerPromotionTransactions')
      .doc(rideRef.id)
      .get(),
  ]);
  assert.equal(result.passengerPromoApplied, true);
  assert.equal(result.passengerDiscountAmount, 10);
  assert.equal(result.passengerAmountDue, 15);
  assert.equal(result.platformSubsidyAmount, 10);
  assert.equal(ride.data().passengerDiscountAmount, 10);
  assert.equal(ride.data().passengerAmountDue, 15);
  assert.equal(ride.data().paymentStatus, 'PROMO_PENDIENTE_LIQUIDACION');
  assert.equal(ride.data().passengerCompletedRideNumber, 1);
  assert.equal(passengerProfile.data().completedRidesCount, 1);
  assert.equal(ride.data().commissionAmount, 0);
  assert.equal(ride.data().commissionWaived, true);
  assert.equal(ride.data().commissionWaivedReason, 'passenger_promotion');
  assert.equal(ride.data().driverBonusAmount, 10);
  assert.equal(driverProfile.data().saldoBilletera, 10);
  assert.equal(subsidy.data().driverBonusAmount, 10);
  assert.equal(subsidy.data().passengerDiscountAmount, 10);
  assert.equal(subsidy.data().passengerAmountDue, 15);
  assert.equal(subsidy.data().commissionAmount, 0);
  assert.equal(subsidy.data().settlementStatus, 'PENDING');
  const countResult = await invokeCallable(
    'contarViajesFinalizados',
    passenger,
  );
  assert.equal(countResult.response.ok, true, JSON.stringify(countResult.payload));
  assert.equal(countResult.payload.result.completedRideCount, 1);
  const retryResult = await finishRide(driver, rideRef.id);
  const driverAfterRetry = await firestore
    .collection('users')
    .doc(driver.uid)
    .get();
  assert.equal(retryResult.driverBonusAmount, 10);
  assert.equal(driverAfterRetry.data().saldoBilletera, 10);
});

test('requires a payment method for promotional and regular rides', async () => {
  const promotionalPassenger = await createPassenger();
  const regularPassenger = await createPassenger({ completedRidesCount: 3 });
  for (const passenger of [promotionalPassenger, regularPassenger]) {
    const noMethodResult = await requestRide(passenger, null);
    assert.equal(noMethodResult.response.ok, false);
    assert.match(noMethodResult.payload.error.message, /método de pago/i);
  }
});

test('records a selected payment method after the promotion limit', async () => {
  const passenger = await createPassenger({ completedRidesCount: 3 });
  const driver = await createDriver(
    new Date(Date.now() - 15 * 24 * 60 * 60 * 1000),
  );
  const { response, payload } = await requestRide(passenger, 'apple_pay');
  assert.equal(response.ok, true, JSON.stringify(payload));
  const fourthRideRef = firestore
    .collection('rides')
    .doc(payload.result.tripId);
  await fourthRideRef.update({
    estado: 'EN_CURSO',
    conductorUid: driver.uid,
  });
  const fourthRideResult = await finishRide(driver, fourthRideRef.id);
  const ride = await fourthRideRef.get();

  assert.equal(ride.data().promotionalEligibleAtRequest, false);
  assert.equal(ride.data().paymentMethod, 'apple_pay');
  assert.equal(ride.data().passengerAmountDue, 25);
  assert.equal(fourthRideResult.passengerPromoApplied, false);
  assert.equal(fourthRideResult.platformSubsidyAmount, 0);
  assert.equal(fourthRideResult.driverBonusAmount, 0);
  assert.equal(fourthRideResult.commissionAmount, 5);
  assert.equal(ride.data().paymentStatus, 'PENDIENTE');
  const driverProfile = await firestore
    .collection('users')
    .doc(driver.uid)
    .get();
  assert.equal(driverProfile.data().saldoBilletera, -5);
});

test.after(async () => {
  await deleteApp(adminApp);
});
