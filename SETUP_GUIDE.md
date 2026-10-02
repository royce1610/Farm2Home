# Farm2Home — farmer payments and order cancellation

## Update your current working project

Your original database migration has already succeeded. Keep `schema.sql` and `migration.sql` in your VS Code/GitHub folder as setup history. Do not run those files again for this update.

1. Back up your current `index.html`, especially if you made local changes.
2. Add `migration_002_payments_cancellation.sql` to the same project folder.
3. Open this new SQL file in VS Code, copy the entire file, paste it into a new query in your Farm2Home Supabase project's SQL Editor, and click Run. Wait for success.
4. Replace your current `index.html` with the updated HTML file. If the downloaded filename has a number appended, rename it to `index.html`. Your existing Supabase project URL and public publishable key are retained; check them if you changed projects locally.
5. Refresh the website. Log in as a farmer and open Dashboard → Your payment settings.
6. Save your own UPI ID and payee name, then enable “Accept UPI payments.” Leave it disabled to use cash on delivery.
7. Commit the new SQL file, updated HTML and this guide to GitHub. Committing SQL does not run it; step 3 applies the database update.

The new SQL update can safely be run again if needed. It preserves current settings and orders. The earlier `migration.sql` was a one-time migration; do not rerun it.

## Farmer payment settings

Each farmer has their own UPI ID, payee name and enable/disable setting. Only that farmer can change their settings. The destination is visible to signed-in customers for payments. Cash on delivery remains available.

Existing orders retain their saved payment destination even if a farmer later changes or disables their UPI ID. Changes apply to new orders only. The old central `PAYMENT_CONFIG` is no longer used for new orders.

## Customer checkout and payments

- Add products and enter a delivery address.
- Choose cash on delivery or UPI, then place the order.
- The database calculates the actual total, checks stock and creates a separate payment record for each farmer.
- If any farmer in the basket has not enabled UPI, UPI checkout is rejected and all stock/order changes roll back. Choose cash on delivery or adjust the basket.
- For UPI, open My orders after checkout. Each farm has its own amount, payee name, UPI ID and Open UPI app link. On a desktop, use your phone to pay the displayed UPI ID and exact amount if the link cannot open an app.
- Confirm the recipient shown in your UPI app, pay the farmer, then submit the transaction reference for that farm. If already paid, submit the reference without paying again.
- A reference is not proof of payment. The farmer checks their bank/UPI statement and clicks Confirm money received only after receiving the full amount.
- For cash on delivery, the farmer records collection after marking all their items in that order fulfilled.

There is no automatic gateway verification, card checkout, settlement or refund service. No private payment keys or bank account credentials are needed in the HTML. Never enter a Supabase service-role key into frontend code.

## Cancellation

The customer sees Cancel order while the order is placed and every item is still unconfirmed. Cancelling requires a confirmation click.

The database checks ownership, locks the order, verifies that no farmer confirmed any item, marks all items cancelled and restores their stock in the same transaction. Repeated cancellation requests do not restore stock a second time. A farmer cannot confirm a cancelled order. Cancelled orders are excluded from the farmer's order-value total.

Cancellation affects the entire order. Once any farm confirms an item, the customer must contact the farmer instead; partial cancellation is not included.

All cancelled UPI orders are marked for refund review because a customer may have transferred money before submitting a reference. This does not mean a payment was received or that a refund happened. The customer and farmer must verify the receipt and arrange any required refund directly. Payment links disappear from cancelled orders. A trusted database operator can record `refunded` in the relevant `order_payments` row only after a refund actually completes.

Orders placed before update 002 remain visible and use their original payment records/destination. They are not redirected to newly configured farmer UPI IDs. For a refund on an earlier order, contact the original payment recipient. Unconfirmed earlier orders can still be cancelled, with stock restored.

## Quick test

1. Farmer: enter UPI settings and save. Add a product with stock 10.
2. Customer: place a cash-on-delivery order for 2 units. Check stock is 8.
3. Cancel it before farmer confirmation. Check stock returns to 10 and order status says cancelled.
4. Place another order. Farmer: confirm one item. Customer: cancellation must now be unavailable/rejected.
5. UPI: place an order involving one or more configured farms. Verify each farm has a separate exact amount and payment destination.
6. Submit a real reference only after paying. Farmer: verify the real receipt before confirming money received.
7. Change a farmer's UPI ID and confirm that an earlier order still shows the original destination.

## Validation completed

The new migration executed successfully in an isolated PostgreSQL environment using PGlite, including a second run to verify repeatability. Database tests covered farmer settings permissions, multi-farmer totals, missing-UPI rollback, saved destinations, payment ownership, receipt confirmation, stock restoration only once, cancellation restrictions, invalid quantities, insufficient stock, COD collection rules and reviews on cancelled purchases.

Automated DOM interaction tests covered the updated forms, order-first payment flow, payment links and references, cancellation controls, refund notices and cancelled sales totals. JavaScript and PL/pgSQL syntax checks passed.

These are isolated tests. This update has not been applied to your live Supabase project, and no live transfer or automatic payment verification was performed. Visual browser testing remains outstanding.
