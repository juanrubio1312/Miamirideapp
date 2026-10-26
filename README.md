# Miamirideapp

## Project structure

The canonical Flutter apps are:

- `RUNS_passenger_app/` — Passenger app.
- `RUNS_driver_app/` — Driver app.
- `shared_service/` — shared `ride_services` package used by both apps.

Each app keeps its entry point in `lib/main.dart`, login UI in
`lib/screens/login_screen.dart`, and role-specific authentication in
`lib/services/auth_service.dart`. The app package names in `pubspec.yaml`
remain `passenger_app` and `driver_app`; those names are used by Dart imports
and do not change which directories are the official app sources.

The shared ride implementation is in
`shared_service/lib/ride_services.dart`. Keep app-specific authentication in
each app and shared ride coordination in that package.

## Passenger and Driver ride flow

Both Flutter apps use the local `ride_services` package in `shared_service/`.
Ride requests are stored as documents in the Firebase Cloud Firestore
`rides` collection, so the Passenger and Driver apps receive the same live
updates instead of relying on process-local memory.

The ride status flow is:

1. Passenger creates a `BUSCANDO` ride.
2. Driver listens for available rides and atomically claims one as `ACEPTADO`.
3. Driver advances the ride through `EN_CURSO` and `FINALIZADO`.
4. Both apps listen to the ride document and update their screens in real time.

Before running either app:

- Enable Cloud Firestore in the Firebase project configured for the apps.
- The root `firebase.json` configures local Authentication, Firestore, and
  Cloud Functions emulators on ports `9099`, `8080`, and `5001`, and the
  Emulator UI on port `4000`.
- Start the installed Android virtual device with
  `flutter emulators --launch Miamiride_API_36`. Allow at least 8 GB of free
  disk before first boot; the Android 36 image allocates a large writable data
  partition.
- For local emulator runs, install the Functions dependencies once with
  `npm --prefix functions install`, then start the emulators from the
  repository root with
  `firebase emulators:start --only auth,firestore,functions --project miamirideapp`.
  The project ID matches
  the Android Firebase configuration; with both apps started using the
  emulator flag below, Auth and Firestore requests go to the local emulators.
  The Firebase CLI does not need to be logged in for this local-only command.
- Run an app on the Android emulator with
  `flutter run --dart-define=USE_FIREBASE_EMULATORS=true`. The default emulator
  host is `10.0.2.2`; override it with
  `--dart-define=FIREBASE_EMULATOR_HOST=<host>` when needed. Without the
  emulator flag, Firebase uses the configured project as usual.
- Run these commands in separate terminals to keep both apps connected to the
  same local Firebase emulators.
- Deploy the root `firestore.rules` file to the Firebase project only when
  deliberately updating production rules. It protects the `users` and `rides`
  collections, permits authenticated reads, and limits client ride updates to
  the driver's accept and start transitions. Ride completion and commission
  accounting are restricted to the trusted callable function. Do not use
  public read/write rules in production.
- Sign both apps into Firebase Auth when using rules that associate rides with
  authenticated user IDs. The current demo screens use fallback IDs when no
  Firebase user is signed in.
- Install dependencies and run checks from the canonical app directories:
  `cd RUNS_passenger_app && flutter pub get && flutter analyze && flutter test`
  and `cd RUNS_driver_app && flutter pub get && flutter analyze && flutter test`.
- Run commission unit tests with `npm --prefix functions test`. To run callable,
  Auth, Firestore, promotion, payment-method, and security-rule integration
  tests, first install Functions dependencies, then run
  `firebase emulators:exec --only auth,firestore,functions --project miamirideapp "npm --prefix functions run test:emulator"`.

Run both apps with the emulator flag above to test passenger and driver flows
against the same local Auth and Firestore instances. Accounts and data in the
Firebase emulators are separate from the configured production Firebase
project.

Documents include passenger and driver IDs, pickup and destination text, fare,
status, and server-managed timestamps. Status changes are performed in
Firestore transactions so two drivers cannot claim the same request.
Completing a ride uses the `finalizarViaje` callable Cloud Function: it
verifies the authenticated driver, applies the normal 20% commission after
the driver's first 14 days unless a passenger promotion waives it, and records
the resulting amount and wallet balance in an atomic Firestore transaction.
The exact 14-day boundary is included in the grace period. Client apps cannot
mark rides complete or change wallet balances directly. Deploy the backend and
rules together with
`firebase deploy --only functions,firestore --project miamirideapp`;
deploying Cloud Functions requires a Firebase project with billing enabled.

Passenger ride requests and completed-ride counts are also handled by trusted
callable functions. The first three completed rides receive a 40% discount:
the passenger owes 60% of the fare and RUNS records the remaining 40% as a
pending platform subsidy. On each of those promotional rides, the driver
commission is waived and the ledger credits the driver's balance with a bonus
equal to the discount, so the promotion does not reduce the driver's agreed
fare. This records the platform subsidy and driver credit, but does not
transfer real money; a payout integration is still required. Passengers must
select cash, credit card, Apple Pay, or Google Pay for every ride. The chosen
method is stored on the ride, but no payment is charged because the app has no
payment provider integration yet. Firestore rules block direct client ride
creation and protect the completed-ride counter.

Passenger referrals use a unique `RUNS-XXXXXXXX` code created by the trusted
`obtenerEstadoReferidos` callable. A passenger can copy the code to send to a
friend, who must apply it before completing their first trip. Each code can be
claimed once; self-referrals and repeat claims are rejected. On the invited
passenger's first completed trip, one atomic transaction credits $10 USD of
referral credit to each passenger and writes a unique reward ledger entry.
Referral codes and balances are stored in the private `referralAccounts`,
`referralCodes`, and `referralRewardTransactions` collections and displayed in
the passenger app. They are promotional credits, not cash withdrawals, and
payment redemption is not available until a payment integration is added.

Passenger registration can create only a passenger profile. Driver registration
creates a `pending_driver` profile and a private `driverApplications` record
through the `solicitarAltaConductor` callable function; the required vehicle
year must be an integer from 2014 through the current year, and the backend
enforces this even if a client bypasses form validation. The year is retained
with the private application for administrator review. Clients cannot read or
write application records or assign driver roles. A trusted administrator
reviews applications with `revisarSolicitudConductor`, which requires the
Firebase Auth custom claim `admin: true` and accepts `approved` or `rejected`.
Assign that claim only from a trusted administrative environment using the
Firebase Admin SDK, never from a client. Approval sets `driverApproved: true`;
ride rules and completion functions require both that marker and the driver
role. Existing driver profiles without the approval marker are blocked until
their identity is reviewed and an administrator sets the approval marker with
the trusted Firebase Admin SDK. Deploy Functions and Firestore rules together
after setting up an administrator claim.