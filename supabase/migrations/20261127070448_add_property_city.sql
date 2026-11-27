alter table public.properties add column if not exists city text check (city is null or (city <> '' and city = upper(btrim(city)) and char_length(city) <= 80));
