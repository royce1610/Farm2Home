-- Farm2Home update 002. Apply AFTER migration.sql, which you already ran.
-- Safe to run again. Existing orders and farmer settings are preserved.
begin;
create table if not exists public.farmer_payment_settings (
 farmer_id uuid primary key references public.profiles(id),
 upi_id text not null default '',
 payee_name text not null default '',
 enabled boolean not null default false,
 check(length(upi_id)<=150 and length(payee_name)<=100),
 check(not enabled or (upi_id ~ '^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+$' and length(trim(payee_name))>0))
);
alter table public.farmer_payment_settings enable row level security;
drop policy if exists "Read farmer payment destinations" on public.farmer_payment_settings;
create policy "Read farmer payment destinations" on public.farmer_payment_settings for select to authenticated using(true);
drop policy if exists "Farmer creates own payment settings" on public.farmer_payment_settings;
create policy "Farmer creates own payment settings" on public.farmer_payment_settings for insert to authenticated with check(farmer_id=auth.uid() and exists(select 1 from public.profiles where id=auth.uid() and role='farmer'));
drop policy if exists "Farmer edits own payment settings" on public.farmer_payment_settings;
create policy "Farmer edits own payment settings" on public.farmer_payment_settings for update to authenticated using(farmer_id=auth.uid()) with check(farmer_id=auth.uid() and exists(select 1 from public.profiles where id=auth.uid() and role='farmer'));
grant select,insert,update on public.farmer_payment_settings to authenticated;

create table if not exists public.order_payments (
 id uuid primary key default gen_random_uuid(),
 order_id uuid not null references public.orders(id),
 farmer_id uuid not null references public.profiles(id),
 customer_id uuid not null references public.profiles(id),
 farm_name text not null,
 amount numeric(10,2) not null check(amount>=0),
 method text not null check(method in ('cod','upi')),
 upi_id text,
 payee_name text,
 status text not null default 'pending' check(status in ('pending','awaiting_verification','paid','cancelled','refund_review','refunded')),
 reference text,
 created_at timestamptz not null default now(),
 unique(order_id,farmer_id)
);
alter table public.order_payments enable row level security;
drop policy if exists "Read own order payments" on public.order_payments;
create policy "Read own order payments" on public.order_payments for select to authenticated using(auth.uid() in (farmer_id,customer_id));
grant select on public.order_payments to authenticated;
revoke insert,update,delete on public.order_payments from anon,authenticated;
create index if not exists idx_order_payments_customer on public.order_payments(customer_id);
create index if not exists idx_order_payments_farmer on public.order_payments(farmer_id);

create or replace function public.checkout(items jsonb,delivery text,method text default 'cod',reference text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare oid uuid; entry record; p products%rowtype; settings farmer_payment_settings%rowtype; amount numeric:=0;
begin
 if auth.uid() is null or not exists(select 1 from profiles where id=auth.uid() and role='customer') then raise exception 'Customer login required';end if;
 if delivery is null or length(trim(delivery))<5 or length(delivery)>1000 then raise exception 'Provide a valid delivery address';end if;
 if method is null or method not in ('cod','upi') then raise exception 'Invalid payment method';end if;
 if method='upi' and nullif(trim(reference),'') is not null then raise exception 'Refresh the website. Place the order first, then pay each farmer in My orders';end if;
 if items is null or jsonb_typeof(items)<>'array' then raise exception 'Invalid basket';end if;
 if jsonb_array_length(items)=0 or jsonb_array_length(items)>100 then raise exception 'Invalid basket';end if;
 if exists(select 1 from jsonb_to_recordset(items) as x(product_id uuid,quantity numeric) where product_id is null or quantity is null or quantity<=0 or quantity::text in ('NaN','Infinity','-Infinity') or quantity<>round(quantity,2)) then raise exception 'Use positive quantities with at most two decimal places';end if;
 insert into orders(customer_id,total,delivery_address,payment_method,payment_status)
 values(auth.uid(),0,trim(delivery),method,'pending') returning id into oid;
 for entry in select product_id,sum(quantity) quantity from jsonb_to_recordset(items) as x(product_id uuid,quantity numeric) group by product_id order by product_id loop
  select * into p from products where id=entry.product_id for update;
  if not found or p.stock<entry.quantity then raise exception 'Product unavailable or insufficient stock';end if;
  update products set stock=stock-entry.quantity where id=p.id;
  insert into order_items(order_id,product_id,farmer_id,product_name,price,quantity,subtotal)
  values(oid,p.id,p.farmer_id,p.name,p.price,entry.quantity,round(p.price*entry.quantity,2));
  amount:=amount+round(p.price*entry.quantity,2);
 end loop;
 -- Snapshot each destination, so editing a UPI ID cannot redirect an existing order.
 for entry in select i.farmer_id,sum(i.subtotal) total,coalesce(f.farm_name,f.name) farm_name
 from order_items i join profiles f on f.id=i.farmer_id where i.order_id=oid group by i.farmer_id,f.farm_name,f.name order by i.farmer_id loop
  settings:=null;
  select * into settings from farmer_payment_settings where farmer_id=entry.farmer_id for share;
  if method='upi' and (settings.farmer_id is null or not settings.enabled) then raise exception 'One or more farms have not enabled UPI. Choose cash on delivery';end if;
  insert into order_payments(order_id,farmer_id,customer_id,farm_name,amount,method,upi_id,payee_name)
  values(oid,entry.farmer_id,auth.uid(),entry.farm_name,entry.total,method,case when method='upi' then settings.upi_id end,case when method='upi' then settings.payee_name end);
 end loop;
 update orders set total=amount where id=oid;
 insert into notifications(user_id,body) select distinct farmer_id,'New order received. Open your dashboard to confirm fulfilment.' from order_items where order_id=oid;
 insert into notifications(user_id,body) values(auth.uid(),case when method='upi' then 'Order placed. Open My orders to pay each farmer directly.' else 'Order placed. Pay each farmer on delivery.' end);
 return oid;
end $$;
revoke all on function public.checkout(jsonb,text,text,text) from public;
grant execute on function public.checkout(jsonb,text,text,text) to authenticated;

-- Order row is always locked first in status/payment/cancellation operations.
-- This serializes cancellation against confirmation and prevents stock restoration twice.
create or replace function public.cancel_order(order_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare o orders%rowtype; entry record;
begin
 select * into o from orders where id=cancel_order.order_id for update;
 if not found or auth.uid() is null or o.customer_id<>auth.uid() then raise exception 'Not authorized';end if;
 if o.status='cancelled' then return;end if;
 if o.status<>'placed' or exists(select 1 from order_items i where i.order_id=o.id and i.status<>'placed') then raise exception 'Cancellation is available only before any farmer confirms. Contact the farmer for help';end if;
 for entry in select product_id,sum(quantity) quantity from order_items i where i.order_id=o.id group by product_id order by product_id loop
  update products set stock=stock+entry.quantity where id=entry.product_id;
 end loop;
 update order_items i set status='cancelled' where i.order_id=o.id;
 update orders set status='cancelled' where id=o.id;
 update order_payments op set status=case when op.method='upi' or op.status in ('paid','awaiting_verification') then 'refund_review' else 'cancelled' end where op.order_id=o.id;
 insert into notifications(user_id,body) select distinct farmer_id,'Order cancelled. Stock restored. Check payment details for any refund review.' from order_items i where i.order_id=o.id;
 insert into notifications(user_id,body) values(o.customer_id,'Order cancelled. If you already paid, contact the farmer to arrange a manual refund.');
end $$;
revoke all on function public.cancel_order(uuid) from public;
grant execute on function public.cancel_order(uuid) to authenticated;

create or replace function public.advance_item(item_id uuid,next_status text) returns void language plpgsql security definer set search_path=public as $$
declare i order_items%rowtype; oid uuid; o orders%rowtype;
begin
 select order_id into oid from order_items where id=item_id;
 select * into o from orders where id=oid for update;
 select * into i from order_items where id=item_id for update;
 if not found or auth.uid() is null or i.farmer_id<>auth.uid() then raise exception 'Not authorized';end if;
 if o.status='cancelled' then raise exception 'This order was cancelled';end if;
 if next_status is null or not((i.status='placed' and next_status='confirmed') or(i.status='confirmed' and next_status='fulfilled')) then raise exception 'Confirm the item first, then mark fulfilled';end if;
 update order_items set status=next_status::order_status where id=item_id;
 update orders set status=case when not exists(select 1 from order_items where order_id=oid and status<>'fulfilled') then 'fulfilled'::order_status when not exists(select 1 from order_items where order_id=oid and status='placed') then 'confirmed'::order_status else 'placed'::order_status end where id=oid;
 insert into notifications(user_id,body) values(o.customer_id,i.product_name||' is now '||next_status||'.');
end $$;
revoke all on function public.advance_item(uuid,text) from public;
grant execute on function public.advance_item(uuid,text) to authenticated;

create or replace function public.submit_payment_reference(payment_id uuid,transaction_reference text) returns void language plpgsql security definer set search_path=public as $$
declare p order_payments%rowtype; oid uuid; order_state order_status;
begin
 select order_id into oid from order_payments where id=payment_id;
 select status into order_state from orders where id=oid for update;
 select * into p from order_payments where id=payment_id for update;
 if not found or auth.uid() is null or p.customer_id<>auth.uid() then raise exception 'Not authorized';end if;
 if p.method<>'upi' or p.status not in ('pending','awaiting_verification') or order_state='cancelled' then raise exception 'This payment cannot be edited. Contact the farmer if you have paid';end if;
 if transaction_reference is null or length(trim(transaction_reference))<6 or length(transaction_reference)>100 then raise exception 'Enter a transaction reference between 6 and 100 characters';end if;
 update order_payments set reference=trim(transaction_reference),status='awaiting_verification' where id=payment_id;
 update orders set payment_status='awaiting_verification' where id=oid;
 insert into notifications(user_id,body) values(p.farmer_id,'Customer submitted a UPI reference. Check your bank receipt before confirming payment.');
end $$;
revoke all on function public.submit_payment_reference(uuid,text) from public;
grant execute on function public.submit_payment_reference(uuid,text) to authenticated;

create or replace function public.confirm_payment(payment_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare p order_payments%rowtype; oid uuid; order_state order_status;
begin
 select order_id into oid from order_payments where id=payment_id;
 select status into order_state from orders where id=oid for update;
 select * into p from order_payments where id=payment_id for update;
 if not found or auth.uid() is null or p.farmer_id<>auth.uid() then raise exception 'Not authorized';end if;
 if p.status='paid' then return;end if;
 if order_state='cancelled' then raise exception 'Order cancelled. Review any received payment for a manual refund';end if;
 if (p.method='upi' and p.status<>'awaiting_verification') or (p.method='cod' and (p.status<>'pending' or exists(select 1 from order_items where order_id=oid and farmer_id=auth.uid() and status<>'fulfilled'))) then raise exception 'UPI needs a reference; cash collection is recorded after your items are fulfilled';end if;
 update order_payments set status='paid' where id=payment_id;
 update orders set payment_status=case when not exists(select 1 from order_payments where order_id=oid and status<>'paid') then 'paid' else 'awaiting_verification' end where id=oid;
 insert into notifications(user_id,body) values(p.customer_id,p.farm_name||' confirmed receiving your payment.');
end $$;
revoke all on function public.confirm_payment(uuid) from public;
grant execute on function public.confirm_payment(uuid) to authenticated;

-- Cancelled purchases cannot be used to create a new review.
drop policy if exists "Purchased product review" on public.reviews;
create policy "Purchased product review" on public.reviews for insert with check(customer_id=auth.uid() and exists(select 1 from public.order_items i join public.orders o on o.id=i.order_id where o.customer_id=auth.uid() and i.product_id=reviews.product_id and i.status<>'cancelled'));
drop policy if exists "Edit own review" on public.reviews;
create policy "Edit own review" on public.reviews for update using(customer_id=auth.uid()) with check(customer_id=auth.uid() and exists(select 1 from public.order_items i join public.orders o on o.id=i.order_id where o.customer_id=auth.uid() and i.product_id=reviews.product_id and i.status<>'cancelled'));
notify pgrst, 'reload schema';
commit;
