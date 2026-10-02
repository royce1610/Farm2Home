-- Apply after your original schema.sql. No existing data is removed.
begin;
alter table public.products add column if not exists image_url text;
alter table public.orders add column if not exists delivery_address text;
alter table public.orders add column if not exists payment_method text not null default 'cod' check(payment_method in ('cod','upi'));
alter table public.orders add column if not exists payment_status text not null default 'pending' check(payment_status in ('pending','awaiting_verification','paid'));
alter table public.orders add column if not exists payment_reference text;
alter table public.order_items add column if not exists status public.order_status not null default 'placed';
update public.order_items i set status=o.status from public.orders o where o.id=i.order_id;
-- Public listings must not expose personal email, mobile or delivery address.
drop policy if exists "Profiles are viewable by everyone" on public.profiles;
create policy "Read own profile" on public.profiles for select using(id=auth.uid());
create or replace view public.farmer_directory as select id,name,farm_name,farm_location from public.profiles where role='farmer';
grant select on public.farmer_directory to anon,authenticated;
-- Remove mutually recursive order policies; membership helper bypasses RLS safely.
create or replace function public.is_order_farmer(oid uuid) returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from order_items where order_id=oid and farmer_id=auth.uid()) $$;
drop policy if exists "Farmers can view orders containing their products" on public.orders;
create policy "Farmer reads assigned order" on public.orders for select using(public.is_order_farmer(id));
-- Account role cannot be changed to gain different privileges.
create or replace function public.preserve_profile_role() returns trigger language plpgsql set search_path=public as $$ begin if new.role is distinct from old.role then raise exception 'Account role cannot be changed';end if;return new;end $$;
create trigger preserve_role before update on public.profiles for each row execute function public.preserve_profile_role();
-- Checkout is exclusively server-priced and atomic.
drop policy if exists "Customers can create their own orders" on public.orders;
drop policy if exists "Customers can insert order items for their own orders" on public.order_items;
drop trigger if exists trg_deduct_stock on public.order_items;
create table if not exists public.reviews(id uuid primary key default gen_random_uuid(),customer_id uuid not null references public.profiles(id),product_id uuid not null references public.products(id),rating integer not null check(rating between 1 and 5),body text not null check(length(body) between 1 and 1000),created_at timestamptz not null default now(),unique(customer_id,product_id));
alter table public.reviews enable row level security;
create policy "Read reviews" on public.reviews for select using(true);
create policy "Purchased product review" on public.reviews for insert with check(customer_id=auth.uid() and exists(select 1 from public.order_items i join public.orders o on o.id=i.order_id where o.customer_id=auth.uid() and i.product_id=reviews.product_id));
create policy "Edit own review" on public.reviews for update using(customer_id=auth.uid()) with check(customer_id=auth.uid() and exists(select 1 from public.order_items i join public.orders o on o.id=i.order_id where o.customer_id=auth.uid() and i.product_id=reviews.product_id));
create table if not exists public.messages(id uuid primary key default gen_random_uuid(),sender_id uuid not null references public.profiles(id),recipient_id uuid not null references public.profiles(id),body text not null check(length(trim(body)) between 1 and 2000),created_at timestamptz not null default now(),check(sender_id<>recipient_id));
alter table public.messages enable row level security;
create policy "Read own conversations" on public.messages for select using(auth.uid() in(sender_id,recipient_id));
create policy "Send own messages" on public.messages for insert with check(sender_id=auth.uid() and exists(select 1 from public.profiles p where p.id=recipient_id and p.role<>(select role from public.profiles where id=auth.uid())));
-- Recipient check uses a security definer because profiles are private.
create or replace function public.can_message(recipient uuid) returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from profiles a join profiles b on a.role<>b.role where a.id=auth.uid() and b.id=recipient) $$;
drop policy "Send own messages" on public.messages;
create policy "Send own messages" on public.messages for insert with check(sender_id=auth.uid() and public.can_message(recipient_id));
create table if not exists public.notifications(id uuid primary key default gen_random_uuid(),user_id uuid not null references public.profiles(id),body text not null,created_at timestamptz not null default now());
alter table public.notifications enable row level security;
create policy "Read own notifications" on public.notifications for select using(user_id=auth.uid());
create or replace function public.checkout(items jsonb,delivery text,method text default 'cod',reference text default null) returns uuid language plpgsql security definer set search_path=public as $$
declare oid uuid; entry record; p products%rowtype; amount numeric:=0;
begin
 if auth.uid() is null or not exists(select 1 from profiles where id=auth.uid() and role='customer') then raise exception 'Customer login required'; end if;
 if length(trim(delivery))<5 or length(delivery)>1000 then raise exception 'Provide a valid delivery address'; end if;
 if method not in ('cod','upi') then raise exception 'Invalid payment method'; end if;
 if method='upi' and (reference is null or length(trim(reference))<6 or length(reference)>100) then raise exception 'Provide your UPI transaction reference'; end if;
 if jsonb_typeof(items)<>'array' or jsonb_array_length(items)=0 or jsonb_array_length(items)>100 then raise exception 'Invalid basket'; end if;
 if exists(select 1 from jsonb_to_recordset(items) as x(product_id uuid,quantity numeric) where product_id is null or quantity is null or quantity<=0) then raise exception 'Invalid basket item'; end if;
 insert into orders(customer_id,total,delivery_address,payment_method,payment_status,payment_reference) values(auth.uid(),0,trim(delivery),method,case when method='upi' then 'awaiting_verification' else 'pending' end,case when method='upi' then trim(reference) else null end) returning id into oid;
 -- Deterministic lock order prevents deadlocks. Duplicate products are grouped.
 for entry in select product_id,sum(quantity) quantity from jsonb_to_recordset(items) as x(product_id uuid,quantity numeric) group by product_id order by product_id loop
  if entry.quantity is null or entry.quantity<=0 then raise exception 'Invalid quantity'; end if;
  select * into p from products where id=entry.product_id for update;
  if not found or p.stock<entry.quantity then raise exception 'Product unavailable or insufficient stock'; end if;
  update products set stock=stock-entry.quantity where id=p.id;
  insert into order_items(order_id,product_id,farmer_id,product_name,price,quantity,subtotal) values(oid,p.id,p.farmer_id,p.name,p.price,entry.quantity,p.price*entry.quantity);
  amount:=amount+p.price*entry.quantity;
 end loop;
 update orders set total=amount where id=oid;
 insert into notifications(user_id,body) select distinct farmer_id,'New order received. Open your dashboard to confirm fulfilment.' from order_items where order_id=oid;
 insert into notifications(user_id,body) values(auth.uid(),'Order placed. Track each farm’s progress in My orders.');
 return oid;
end $$;
revoke all on function public.checkout(jsonb,text,text,text) from public;
grant execute on function public.checkout(jsonb,text,text,text) to authenticated;
create or replace function public.advance_item(item_id uuid,next_status text) returns void language plpgsql security definer set search_path=public as $$
declare i order_items%rowtype; customer uuid;
begin
 select * into i from order_items where id=item_id for update;
 if not found or i.farmer_id<>auth.uid() or auth.uid() is null then raise exception 'Not authorized'; end if;
 if not((i.status='placed' and next_status='confirmed') or(i.status='confirmed' and next_status='fulfilled')) then raise exception 'Confirm the item first, then mark fulfilled'; end if;
 perform 1 from orders where id=i.order_id for update;
 update order_items set status=next_status::order_status where id=item_id;
 update orders set status=case when not exists(select 1 from order_items where order_id=i.order_id and status<>'fulfilled') then 'fulfilled'::order_status when not exists(select 1 from order_items where order_id=i.order_id and status='placed') then 'confirmed'::order_status else 'placed'::order_status end where id=i.order_id returning customer_id into customer;
 insert into notifications(user_id,body) values(customer,i.product_name||' is now '||next_status||'.');
end $$;
revoke all on function public.advance_item(uuid,text) from public;
grant execute on function public.advance_item(uuid,text) to authenticated;
create or replace function public.message_notification() returns trigger language plpgsql security definer set search_path=public as $$ begin insert into notifications(user_id,body) values(new.recipient_id,'New message. Open Messages to read and reply.');return new;end $$;
create trigger notify_message after insert on public.messages for each row execute function public.message_notification();
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('product-images','product-images',true,5242880,array['image/jpeg','image/png','image/webp','image/gif']) on conflict(id) do nothing;
create policy "Public product photos" on storage.objects for select using(bucket_id='product-images');
create policy "Farmers upload own photos" on storage.objects for insert with check(bucket_id='product-images' and (storage.foldername(name))[1]=auth.uid()::text and exists(select 1 from public.profiles where id=auth.uid() and role='farmer'));
create index if not exists idx_messages_recipient on public.messages(recipient_id,created_at);
create index if not exists idx_notifications_user on public.notifications(user_id,created_at);
commit;
