const { randomBytes } = require('node:crypto');
const { initializeApp } = require('firebase-admin/app');
const { FieldValue, getFirestore } = require('firebase-admin/firestore');
const { HttpsError, onCall } = require('firebase-functions/v2/https');

const {
  COMMISSION_RATE,
  PASSENGER_DISCOUNT_RATE,
  PASSENGER_PROMOTIONAL_RIDE_LIMIT,
  PASSENGER_PAYMENT_METHODS,
  calculateCommissionCents,
  calculatePassengerDiscountCents,
  isInGracePeriod,
} = require('./commission');

const MINIMUM_VEHICLE_YEAR = 2014;
const REFERRAL_REWARD_CENTS = 1000;

initializeApp();

async function getCompletedRideCount(transaction, passengerUid, profile) {
  const storedCount = profile.completedRidesCount;
  if (
    Number.isInteger(storedCount) &&
    storedCount >= 0
  ) {
    return storedCount;
  }

  const completedRides = await transaction.get(
    getFirestore()
      .collection('rides')
      .where('pasajeroUid', '==', passengerUid)
      .where('estado', '==', 'FINALIZADO'),
  );
  return completedRides.size;
}

exports.contarViajesFinalizados = onCall(async (request) => {
  const passengerUid = request.auth?.uid;
  if (!passengerUid) {
    throw new HttpsError('unauthenticated', 'Debes iniciar sesión.');
  }

  const firestore = getFirestore();
  const passengerRef = firestore.collection('users').doc(passengerUid);
  return firestore.runTransaction(async (transaction) => {
    const passengerSnapshot = await transaction.get(passengerRef);
    if (
      !passengerSnapshot.exists ||
      passengerSnapshot.data().role !== 'passenger'
    ) {
      throw new HttpsError(
        'permission-denied',
        'La cuenta no es de un pasajero.',
      );
    }

    const completedRideCount = await getCompletedRideCount(
      transaction,
      passengerUid,
      passengerSnapshot.data(),
    );
    return {
      completedRideCount,
      discountedRidesRemaining: Math.max(
        0,
        PASSENGER_PROMOTIONAL_RIDE_LIMIT - completedRideCount,
      ),
    };
  });
});

exports.obtenerEstadoReferidos = onCall(async (request) => {
  const passengerUid = request.auth?.uid;
  if (!passengerUid) {
    throw new HttpsError('unauthenticated', 'Debes iniciar sesión.');
  }

  const firestore = getFirestore();
  const passengerRef = firestore.collection('users').doc(passengerUid);
  const accountRef = firestore.collection('referralAccounts').doc(passengerUid);
  const referralCodes = firestore.collection('referralCodes');

  for (let attempt = 0; attempt < 3; attempt += 1) {
    const candidateCode = `RUNS-${randomBytes(4).toString('hex').toUpperCase()}`;
    const result = await firestore.runTransaction(async (transaction) => {
      const [passengerSnapshot, accountSnapshot] = await Promise.all([
        transaction.get(passengerRef),
        transaction.get(accountRef),
      ]);
      if (
        !passengerSnapshot.exists ||
        passengerSnapshot.data().role !== 'passenger'
      ) {
        throw new HttpsError(
          'permission-denied',
          'La cuenta no es de un pasajero.',
        );
      }

      const profile = passengerSnapshot.data();
      const account = accountSnapshot.data() ?? {};
      const existingCode =
        typeof account.referralCode === 'string' &&
        account.referralCode.length > 0
          ? account.referralCode
          : null;
      const referralCode = existingCode ?? candidateCode;
      const codeRef = referralCodes.doc(referralCode);
      const codeSnapshot = await transaction.get(codeRef);

      if (existingCode) {
        if (
          !/^[A-Z0-9-]{4,32}$/.test(existingCode) ||
          !codeSnapshot.exists ||
          codeSnapshot.data().ownerUid !== passengerUid
        ) {
          throw new HttpsError(
            'failed-precondition',
            'El código de invitación de esta cuenta no es válido.',
          );
        }
      } else if (codeSnapshot.exists) {
        return { collision: true };
      }

      const completedRideCount = await getCompletedRideCount(
        transaction,
        passengerUid,
        profile,
      );
      const referralCreditBalance = account.referralCreditBalance ?? 0;
      if (
        typeof referralCreditBalance !== 'number' ||
        !Number.isFinite(referralCreditBalance) ||
        referralCreditBalance < 0
      ) {
        throw new HttpsError(
          'failed-precondition',
          'El saldo de invitaciones de esta cuenta no es válido.',
        );
      }

      if (!existingCode) {
        transaction.create(codeRef, {
          ownerUid: passengerUid,
          referredUid: null,
          createdAt: FieldValue.serverTimestamp(),
        });
        if (accountSnapshot.exists) {
          transaction.update(accountRef, { referralCode });
        } else {
          transaction.create(accountRef, {
            referralCode,
            referralCreditBalance: 0,
            referralRewardGranted: false,
          });
        }
      }

      return {
        collision: false,
        referralCode,
        referralCodeUsed: codeSnapshot.data()?.referredUid != null,
        referralCreditBalance,
        referralApplied: typeof account.referredByUid === 'string',
        referralRewardGranted: account.referralRewardGranted === true,
        canApplyReferral:
          completedRideCount === 0 &&
          typeof account.referredByUid !== 'string',
      };
    });

    if (!result.collision) return result;
  }

  throw new HttpsError(
    'resource-exhausted',
    'No se pudo generar un código de invitación. Inténtalo de nuevo.',
  );
});

exports.aplicarCodigoInvitacion = onCall(async (request) => {
  const passengerUid = request.auth?.uid;
  if (!passengerUid) {
    throw new HttpsError('unauthenticated', 'Debes iniciar sesión.');
  }

  const rawCode = request.data?.code;
  const code =
    typeof rawCode === 'string' ? rawCode.trim().toUpperCase() : '';
  if (!/^[A-Z0-9-]{4,32}$/.test(code)) {
    throw new HttpsError(
      'invalid-argument',
      'Ingresa un código de invitación válido.',
    );
  }

  const firestore = getFirestore();
  const passengerRef = firestore.collection('users').doc(passengerUid);
  const accountRef = firestore.collection('referralAccounts').doc(passengerUid);
  const codeRef = firestore.collection('referralCodes').doc(code);
  return firestore.runTransaction(async (transaction) => {
    const [passengerSnapshot, accountSnapshot, codeSnapshot] = await Promise.all([
      transaction.get(passengerRef),
      transaction.get(accountRef),
      transaction.get(codeRef),
    ]);
    if (
      !passengerSnapshot.exists ||
      passengerSnapshot.data().role !== 'passenger'
    ) {
      throw new HttpsError(
        'permission-denied',
        'La cuenta no es de un pasajero.',
      );
    }
    if (!codeSnapshot.exists) {
      throw new HttpsError(
        'not-found',
        'El código de invitación no existe.',
      );
    }

    const profile = passengerSnapshot.data();
    const account = accountSnapshot.data() ?? {};
    const codeData = codeSnapshot.data();
    const ownerUid = codeData.ownerUid;
    if (typeof ownerUid !== 'string' || ownerUid.length === 0) {
      throw new HttpsError(
        'failed-precondition',
        'El código de invitación no tiene un dueño válido.',
      );
    }
    if (ownerUid === passengerUid) {
      throw new HttpsError(
        'failed-precondition',
        'No puedes usar tu propio código de invitación.',
      );
    }

    const completedRideCount = await getCompletedRideCount(
      transaction,
      passengerUid,
      profile,
    );
    if (completedRideCount > 0) {
      throw new HttpsError(
        'failed-precondition',
        'El código solo se puede aplicar antes de completar tu primer viaje.',
      );
    }
    if (typeof account.referredByUid === 'string') {
      if (
        account.referredByUid === ownerUid &&
        codeData.referredUid === passengerUid
      ) {
        return { applied: true, alreadyApplied: true };
      }
      throw new HttpsError(
        'failed-precondition',
        'Ya aplicaste un código de invitación a esta cuenta.',
      );
    }
    if (codeData.referredUid != null) {
      throw new HttpsError(
        'already-exists',
        'Este código de invitación ya fue utilizado.',
      );
    }

    const ownerRef = firestore.collection('users').doc(ownerUid);
    const ownerSnapshot = await transaction.get(ownerRef);
    if (!ownerSnapshot.exists || ownerSnapshot.data().role !== 'passenger') {
      throw new HttpsError(
        'failed-precondition',
        'El dueño del código de invitación ya no tiene una cuenta válida.',
      );
    }

    const referralFields = {
      referredByUid: ownerUid,
      referralCodeUsed: code,
      referralRewardGranted: false,
    };
    if (accountSnapshot.exists) {
      transaction.update(accountRef, referralFields);
    } else {
      transaction.create(accountRef, {
        ...referralFields,
        referralCreditBalance: 0,
      });
    }
    transaction.update(codeRef, {
      referredUid: passengerUid,
      usedAt: FieldValue.serverTimestamp(),
    });
    return { applied: true, alreadyApplied: false };
  });
});

exports.solicitarAltaConductor = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError('unauthenticated', 'Debes iniciar sesión.');
  }

  const { nombre, numeroDocumento, vehicleYear } = request.data ?? {};
  const normalizedName = typeof nombre === 'string' ? nombre.trim() : '';
  const normalizedDocument =
    typeof numeroDocumento === 'string' ? numeroDocumento.trim() : '';
  const email = request.auth.token.email;

  if (
    normalizedName.length < 2 ||
    normalizedName.length > 120 ||
    normalizedDocument.length < 3 ||
    normalizedDocument.length > 64 ||
    !Number.isInteger(vehicleYear) ||
    vehicleYear < MINIMUM_VEHICLE_YEAR ||
    vehicleYear > new Date().getFullYear() ||
    typeof email !== 'string' ||
    email.length === 0
  ) {
    throw new HttpsError(
      'invalid-argument',
      `El nombre, documento, correo y año del vehículo deben ser válidos. El vehículo debe ser modelo ${MINIMUM_VEHICLE_YEAR} o posterior.`,
    );
  }

  const firestore = getFirestore();
  const userRef = firestore.collection('users').doc(uid);
  const applicationRef = firestore.collection('driverApplications').doc(uid);
  const application = {
    uid,
    nombre: normalizedName,
    email,
    numeroDocumento: normalizedDocument,
    vehicleYear,
    status: 'pending',
    requestedAt: FieldValue.serverTimestamp(),
  };

  return firestore.runTransaction(async (transaction) => {
    const [userSnapshot, applicationSnapshot, matchingUsers, matchingRequests] =
      await Promise.all([
        transaction.get(userRef),
        transaction.get(applicationRef),
        transaction.get(
          firestore
            .collection('users')
            .where('numeroDocumento', '==', normalizedDocument),
        ),
        transaction.get(
          firestore
            .collection('driverApplications')
            .where('numeroDocumento', '==', normalizedDocument),
        ),
      ]);

    if (userSnapshot.exists || applicationSnapshot.exists) {
      throw new HttpsError(
        'already-exists',
        'Esta cuenta ya tiene un perfil o una solicitud de conductor.',
      );
    }
    if (
      matchingUsers.docs.some((document) => document.id !== uid) ||
      matchingRequests.docs.some((document) => document.id !== uid)
    ) {
      throw new HttpsError(
        'already-exists',
        'Este número de documento ya está asociado a otra cuenta.',
      );
    }

    transaction.create(userRef, {
      uid,
      nombre: normalizedName,
      email,
      numeroDocumento: normalizedDocument,
      vehicleYear,
      role: 'pending_driver',
      driverApproved: false,
      driverApprovalStatus: 'pending',
      createdAt: FieldValue.serverTimestamp(),
    });
    transaction.create(applicationRef, application);

    return { status: 'pending' };
  });
});

exports.revisarSolicitudConductor = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError('unauthenticated', 'Debes iniciar sesión.');
  }
  if (request.auth.token.admin !== true) {
    throw new HttpsError(
      'permission-denied',
      'Solo un administrador puede revisar solicitudes de conductor.',
    );
  }

  const { uid, decision } = request.data ?? {};
  if (
    typeof uid !== 'string' ||
    uid.trim().length === 0 ||
    !['approved', 'rejected'].includes(decision)
  ) {
    throw new HttpsError(
      'invalid-argument',
      'El usuario y la decisión de revisión deben ser válidos.',
    );
  }

  const firestore = getFirestore();
  const applicationRef = firestore.collection('driverApplications').doc(uid);
  const userRef = firestore.collection('users').doc(uid);

  return firestore.runTransaction(async (transaction) => {
    const [applicationSnapshot, userSnapshot] = await Promise.all([
      transaction.get(applicationRef),
      transaction.get(userRef),
    ]);
    if (
      !applicationSnapshot.exists ||
      applicationSnapshot.data().status !== 'pending' ||
      !userSnapshot.exists ||
      userSnapshot.data().role !== 'pending_driver'
    ) {
      throw new HttpsError(
        'failed-precondition',
        'La solicitud no existe o ya fue revisada.',
      );
    }

    const approved = decision === 'approved';
    transaction.update(applicationRef, {
      status: decision,
      reviewedAt: FieldValue.serverTimestamp(),
      reviewedBy: request.auth.uid,
    });
    transaction.update(userRef, {
      role: approved ? 'driver' : 'rejected_driver',
      driverApproved: approved,
      driverApprovalStatus: decision,
      ...(approved
        ? {
            createdAt: FieldValue.serverTimestamp(),
            saldoBilletera: 0,
          }
        : {}),
    });

    return { status: decision };
  });
});

exports.crearSolicitudViaje = onCall(async (request) => {
  const passengerUid = request.auth?.uid;
  if (!passengerUid) {
    throw new HttpsError('unauthenticated', 'Debes iniciar sesión.');
  }

  const { origen, destino, tarifa, paymentMethod } = request.data ?? {};
  if (
    typeof origen !== 'string' ||
    origen.trim().length === 0 ||
    typeof destino !== 'string' ||
    destino.trim().length === 0 ||
    typeof tarifa !== 'number' ||
    !Number.isFinite(tarifa) ||
    tarifa <= 0
  ) {
    throw new HttpsError(
      'invalid-argument',
      'El origen, destino y tarifa del viaje deben ser válidos.',
    );
  }
  if (
    paymentMethod != null &&
    !PASSENGER_PAYMENT_METHODS.includes(paymentMethod)
  ) {
    throw new HttpsError(
      'invalid-argument',
      'El método de pago seleccionado no es válido.',
    );
  }
  if (!PASSENGER_PAYMENT_METHODS.includes(paymentMethod)) {
    throw new HttpsError(
      'failed-precondition',
      'Selecciona un método de pago para solicitar este viaje.',
    );
  }

  const firestore = getFirestore();
  const passengerRef = firestore.collection('users').doc(passengerUid);
  const rideRef = firestore.collection('rides').doc();
  return firestore.runTransaction(async (transaction) => {
    const passengerSnapshot = await transaction.get(passengerRef);
    if (
      !passengerSnapshot.exists ||
      passengerSnapshot.data().role !== 'passenger'
    ) {
      throw new HttpsError(
        'permission-denied',
        'La cuenta no es de un pasajero.',
      );
    }

    const completedRideCount = await getCompletedRideCount(
      transaction,
      passengerUid,
      passengerSnapshot.data(),
    );
    const promotionalEligibleAtRequest =
      completedRideCount < PASSENGER_PROMOTIONAL_RIDE_LIMIT;
    const fareCents = Math.round(tarifa * 100);
    const passengerDiscountCents = promotionalEligibleAtRequest
      ? calculatePassengerDiscountCents(tarifa)
      : 0;
    const passengerDiscountAmount = passengerDiscountCents / 100;
    const passengerAmountDue = (fareCents - passengerDiscountCents) / 100;

    transaction.create(rideRef, {
      pasajero: passengerSnapshot.data().nombre ?? 'Pasajero',
      pasajeroUid: passengerUid,
      origen: origen.trim(),
      destino: destino.trim(),
      tarifa,
      estado: 'BUSCANDO',
      conductorAsignado: null,
      conductorUid: null,
      promotionalEligibleAtRequest,
      passengerDiscountRate: promotionalEligibleAtRequest
        ? PASSENGER_DISCOUNT_RATE
        : 0,
      passengerDiscountAmount,
      passengerAmountDue,
      paymentMethod,
      paymentStatus: promotionalEligibleAtRequest
        ? 'PROMO_PENDIENTE'
        : 'PENDIENTE',
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    return {
      tripId: rideRef.id,
      completedRideCount,
      promotionalEligibleAtRequest,
    };
  });
});

exports.finalizarViaje = onCall(async (request) => {
  const conductorUid = request.auth?.uid;
  if (!conductorUid) {
    throw new HttpsError('unauthenticated', 'Debes iniciar sesión.');
  }

  const requestedTripId = request.data?.tripId;
  if (
    typeof requestedTripId !== 'string' ||
    requestedTripId.trim().length === 0
  ) {
    throw new HttpsError(
      'invalid-argument',
      'El identificador del viaje no es válido.',
    );
  }
  const tripId = requestedTripId.trim();

  const firestore = getFirestore();
  const rideRef = firestore.collection('rides').doc(tripId);
  const driverRef = firestore.collection('users').doc(conductorUid);
  const passengerRef = firestore.collection('users');
  const commissionRef = firestore
    .collection('commissionTransactions')
    .doc(tripId);
  const promotionRef = firestore
    .collection('passengerPromotionTransactions')
    .doc(tripId);

  return firestore.runTransaction(async (transaction) => {
    const [rideSnapshot, driverSnapshot, commissionSnapshot] =
      await Promise.all([
        transaction.get(rideRef),
        transaction.get(driverRef),
        transaction.get(commissionRef),
      ]);

    if (
      !driverSnapshot.exists ||
      driverSnapshot.data().role !== 'driver' ||
      driverSnapshot.data().driverApproved !== true
    ) {
      throw new HttpsError(
        'permission-denied',
        'La cuenta no es de un conductor.',
      );
    }

    if (!rideSnapshot.exists) {
      throw new HttpsError('not-found', 'No se encontró el viaje.');
    }

    const ride = rideSnapshot.data();
    if (ride.conductorUid !== conductorUid) {
      throw new HttpsError(
        'permission-denied',
        'Este viaje no pertenece al conductor.',
      );
    }

    if (
      ride.estado === 'FINALIZADO' &&
      commissionSnapshot.exists
    ) {
      const commission = commissionSnapshot.data();
      return {
        completed: true,
        commissionAmount: commission.commissionAmount,
        commissionWaived: commission.commissionWaived,
        commissionWaivedReason: commission.commissionWaivedReason,
        driverBonusAmount: commission.driverBonusAmount ?? 0,
        passengerPromoApplied: commission.passengerPromoApplied ?? false,
        platformSubsidyAmount: commission.platformSubsidyAmount ?? 0,
        passengerDiscountAmount:
          commission.passengerDiscountAmount ??
          (commission.passengerPromoApplied ? ride.tarifa : 0),
        passengerAmountDue:
          commission.passengerAmountDue ??
          (commission.passengerPromoApplied ? 0 : ride.tarifa),
        referralRewardAmount: commission.referralRewardAmount ?? 0,
      };
    }

    if (ride.estado !== 'EN_CURSO') {
      throw new HttpsError(
        'failed-precondition',
        'El viaje debe estar en curso para finalizarlo.',
      );
    }

    const driver = driverSnapshot.data();
    const createdAt = driver.createdAt;
    if (!createdAt || typeof createdAt.toDate !== 'function') {
      throw new HttpsError(
        'failed-precondition',
        'El perfil del conductor no tiene una fecha de registro válida.',
      );
    }

    const now = new Date();
    const registrationDate = createdAt.toDate();
    if (
      !Number.isFinite(registrationDate.getTime()) ||
      registrationDate.getTime() > now.getTime()
    ) {
      throw new HttpsError(
        'failed-precondition',
        'La fecha de registro del conductor no es válida.',
      );
    }

    const fare = ride.tarifa;
    const balance = driver.saldoBilletera;
    if (typeof fare !== 'number' || !Number.isFinite(fare) || fare <= 0) {
      throw new HttpsError(
        'failed-precondition',
        'La tarifa del viaje no es válida.',
      );
    }
    if (typeof balance !== 'number' || !Number.isFinite(balance)) {
      throw new HttpsError(
        'failed-precondition',
        'El saldo del conductor no es válido.',
      );
    }

    const ridePassengerUid = ride.pasajeroUid;
    if (
      typeof ridePassengerUid !== 'string' ||
      ridePassengerUid.length === 0
    ) {
      throw new HttpsError(
        'failed-precondition',
        'El viaje no tiene un pasajero válido.',
      );
    }
    const ridePassengerRef = passengerRef.doc(ridePassengerUid);
    const passengerAccountRef = firestore
      .collection('referralAccounts')
      .doc(ridePassengerUid);
    const referralRewardRef = firestore
      .collection('referralRewardTransactions')
      .doc(ridePassengerUid);
    const [passengerSnapshot, passengerAccountSnapshot] = await Promise.all([
      transaction.get(ridePassengerRef),
      transaction.get(passengerAccountRef),
    ]);
    if (
      !passengerSnapshot.exists ||
      passengerSnapshot.data().role !== 'passenger'
    ) {
      throw new HttpsError(
        'failed-precondition',
        'El perfil del pasajero no es válido.',
      );
    }
    const passengerProfile = passengerSnapshot.data();
    const passengerAccount = passengerAccountSnapshot.data() ?? {};
    const completedRideCount = await getCompletedRideCount(
      transaction,
      ridePassengerUid,
      passengerProfile,
    );
    const referredByUid = passengerAccount.referredByUid;
    if (
      referredByUid != null &&
      (typeof referredByUid !== 'string' || referredByUid.length === 0)
    ) {
      throw new HttpsError(
        'failed-precondition',
        'La invitación asociada al pasajero no es válida.',
      );
    }
    const referralRewardEligible =
      completedRideCount === 0 &&
      typeof referredByUid === 'string' &&
      passengerAccount.referralRewardGranted !== true;
    let referrerRef;
    let referrerAccountRef;
    let referrerSnapshot;
    let referrerAccountSnapshot;
    let referralLedgerSnapshot;
    if (referralRewardEligible) {
      referrerRef = passengerRef.doc(referredByUid);
      referrerAccountRef = firestore
        .collection('referralAccounts')
        .doc(referredByUid);
      [referrerSnapshot, referrerAccountSnapshot, referralLedgerSnapshot] =
        await Promise.all([
          transaction.get(referrerRef),
          transaction.get(referrerAccountRef),
          transaction.get(referralRewardRef),
        ]);
      if (
        !referrerSnapshot.exists ||
        referrerSnapshot.data().role !== 'passenger'
      ) {
        throw new HttpsError(
          'failed-precondition',
          'El dueño del código de invitación ya no tiene una cuenta válida.',
        );
      }
    }
    const referralRewardAmount =
      referralRewardEligible && !referralLedgerSnapshot.exists
        ? REFERRAL_REWARD_CENTS / 100
        : 0;
    const passengerReferralBalance = passengerAccount.referralCreditBalance ?? 0;
    if (
      typeof passengerReferralBalance !== 'number' ||
      !Number.isFinite(passengerReferralBalance) ||
      passengerReferralBalance < 0
    ) {
      throw new HttpsError(
        'failed-precondition',
        'El saldo de invitaciones del pasajero no es válido.',
      );
    }
    let referrerReferralBalance;
    if (referralRewardAmount > 0) {
      referrerReferralBalance =
        referrerAccountSnapshot.data()?.referralCreditBalance ?? 0;
      if (
        typeof referrerReferralBalance !== 'number' ||
        !Number.isFinite(referrerReferralBalance) ||
        referrerReferralBalance < 0
      ) {
        throw new HttpsError(
          'failed-precondition',
          'El saldo de invitaciones del dueño del código no es válido.',
        );
      }
    }
    const passengerPromoApplied =
      completedRideCount < PASSENGER_PROMOTIONAL_RIDE_LIMIT;
    const driverGracePeriod = isInGracePeriod(registrationDate, now);
    const commissionWaived = driverGracePeriod || passengerPromoApplied;
    const commissionWaivedReason = passengerPromoApplied
      ? 'passenger_promotion'
      : driverGracePeriod
        ? 'driver_grace_period'
        : null;
    const commissionCents = commissionWaived
      ? 0
      : calculateCommissionCents(fare);
    const commissionAmount = commissionCents / 100;
    const passengerDiscountCents = passengerPromoApplied
      ? calculatePassengerDiscountCents(fare)
      : 0;
    const driverBonusCents = passengerDiscountCents;
    const driverBonusAmount = driverBonusCents / 100;
    const updatedBalance =
      (Math.round(balance * 100) - commissionCents + driverBonusCents) / 100;
    const passengerDiscountAmount = passengerDiscountCents / 100;
    const fareCents = Math.round(fare * 100);
    const passengerAmountDue = (fareCents - passengerDiscountCents) / 100;
    const platformSubsidyAmount = passengerDiscountAmount;

    transaction.update(rideRef, {
      estado: 'FINALIZADO',
      commissionRate: COMMISSION_RATE,
      commissionAmount,
      commissionWaived,
      commissionWaivedReason,
      driverBonusAmount,
      passengerPromoApplied,
      passengerDiscountRate: passengerPromoApplied
        ? PASSENGER_DISCOUNT_RATE
        : 0,
      passengerDiscountAmount,
      passengerCompletedRideNumber: completedRideCount + 1,
      passengerAmountDue,
      platformSubsidyAmount,
      paymentStatus: passengerPromoApplied
        ? 'PROMO_PENDIENTE_LIQUIDACION'
        : 'PENDIENTE',
      completedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    transaction.update(driverRef, { saldoBilletera: updatedBalance });
    transaction.update(ridePassengerRef, {
      completedRidesCount: completedRideCount + 1,
    });
    if (referralRewardEligible) {
      transaction.update(passengerAccountRef, {
        referralRewardGranted: true,
        ...(referralRewardAmount > 0
          ? {
              referralCreditBalance:
                passengerReferralBalance + referralRewardAmount,
            }
          : {}),
      });
    }
    if (referralRewardAmount > 0) {
      if (referrerAccountSnapshot.exists) {
        transaction.update(referrerAccountRef, {
          referralCreditBalance:
            referrerReferralBalance + referralRewardAmount,
        });
      } else {
        transaction.create(referrerAccountRef, {
          referralCreditBalance: referralRewardAmount,
          referralRewardGranted: false,
        });
      }
      transaction.create(referralRewardRef, {
        invitedUid: ridePassengerUid,
        inviterUid: referredByUid,
        tripId,
        amount: referralRewardAmount,
        currency: 'USD',
        createdAt: FieldValue.serverTimestamp(),
      });
    }
    transaction.create(commissionRef, {
      tripId,
      conductorUid,
      fare,
      commissionRate: COMMISSION_RATE,
      commissionAmount,
      commissionWaived,
      commissionWaivedReason,
      driverBonusAmount,
      passengerPromoApplied,
      platformSubsidyAmount,
      passengerDiscountAmount,
      passengerAmountDue,
      referralRewardAmount,
      createdAt: FieldValue.serverTimestamp(),
    });
    transaction.create(promotionRef, {
      tripId,
      pasajeroUid: ridePassengerUid,
      conductorUid,
      fare,
      passengerPromoApplied,
      platformSubsidyAmount,
      driverBonusAmount,
      commissionAmount,
      commissionWaived,
      commissionWaivedReason,
      passengerDiscountAmount,
      passengerAmountDue,
      settlementStatus: passengerPromoApplied
        ? 'PENDING'
        : 'NOT_APPLICABLE',
      createdAt: FieldValue.serverTimestamp(),
    });

    return {
      completed: true,
      commissionAmount,
      commissionWaived,
      commissionWaivedReason,
      driverBonusAmount,
      passengerPromoApplied,
      platformSubsidyAmount,
      passengerDiscountAmount,
      passengerAmountDue,
      referralRewardAmount,
    };
  });
});
