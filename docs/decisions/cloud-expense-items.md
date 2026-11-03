# Line items: what Cloud accepts

Verified 2026-11-03 against `https://api.spliit.cloud` with a throwaway account
and a scratch group (two members, EUR), by writing expenses and reading them
back. Recorded because the app authors items from this, and the server
documents none of it.

## The payload

`groups.expenses.create` and `.update` take an `expense` object with `items`
and `itemizedRemainder`:

```json
"items": [
  {
    "title": "Starter",
    "unitPrice": 1000,
    "quantity": 1000,
    "amount": 1000,
    "splitMode": "EVENLY",
    "paidFor": [
      { "participant": "<ledgerParticipantId>", "shares": 1 },
      { "participant": "<ledgerParticipantId>", "shares": 1 }
    ]
  }
],
"itemizedRemainder": {
  "splitMode": "EVENLY",
  "allocationMode": "CUSTOM",
  "paidFor": [{ "participant": "<id>", "shares": 1 }]
}
```

- `unitPrice` and `amount` are in the group currency's smallest unit;
  `quantity` is thousandths of a unit, so one item is `1000`.
- `amount` is required and must be `round(unitPrice × quantity / 1000)`. An
  inconsistency is rejected: `400` with `code: "custom", message:
  "amountSum", path: ["expense","items",0,"amount"]`.
- `splitMode` takes the same four values as an expense, and an item's `paidFor`
  shares mean what they mean there (`EVENLY` ignores them, `BY_SHARES` and
  `BY_PERCENTAGE` are ×100, `BY_AMOUNT` is the minor units each owes).
- `sum(items.amount)` must not exceed the expense's `amount`; over it, the
  server answers `400` with `"amountSum"` at `["expense","items"]`. Under it is
  fine — that is the remainder.
- `itemizedRemainder` is an **object**, not an amount; a number is rejected
  with `invalid_type: expected object`. Its `amount` is not sent (it was
  dropped when sent) — the leftover is `expense.amount − sum(items.amount)`.
  Read back, the server adds `"allocationMode": "CUSTOM"` when the client
  didn't send one.
- On read, items come back with server-assigned `id`s and `paidFor` entries as
  `{ "ledgerParticipantId", "shares" }`, which is what `ExpenseItem.fromJson`
  and `_shares` already read.

## What the server does not do

- It does **not** derive the expense-level `paidFor` or `splitMode` from the
  items: an itemized expense written with items that only Ada shares came back
  with `paidFor` as sent (Ada and Bea, evenly). Whatever computes the split is
  the client's, so this app must compute it from the items and send it.
- It does not compute or store `itemizedRemainder` unless the client sends it.
- It does not validate an item's `splitMode` against its `paidFor` (a
  `BY_SHARES` item with shares 300/100 was stored as sent).

## How it was checked

A throwaway anonymous account (`POST /auth/sign-in/anonymous`, then
`POST /auth/anonymous-recovery/setup` and `/acknowledge`, which every group
call requires), a group created by it, and a second throwaway account that
accepted a shared invite so the group had two participants. Requests need an
`origin` of `https://spliit.cloud` and a non-browser user agent: Cloudflare
answers `error code: 1010` to anything else, before the API sees it.
