-- =====================================================================
-- CONTROLE DE ABASTECIMENTOS - BANCO DE DADOS (SUPABASE / POSTGRES)
-- Como usar: Supabase > SQL Editor > New query > cole TUDO > Run.
-- Pode rodar de novo sem medo (os comandos são repetíveis).
-- IMPORTANTE: este arquivo NÃO contém o token do Telegram. Veja o passo C no final.
-- Versão completa: abastecimentos, pagamentos, histórico, avisos e BOT com comandos.
-- =====================================================================

-- 1) EXTENSÃO PARA ENVIAR MENSAGENS AO TELEGRAM (feito pelo banco, não pelo site)
create extension if not exists pg_net with schema extensions;

-- 2) USUÁRIOS E PERMISSÕES
-- papel: 'admin' (registra tudo), 'leitura' (só consulta), 'bloqueado' (sem acesso)
create table if not exists public.perfis (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  nome      text,
  papel     text not null default 'bloqueado' check (papel in ('admin','leitura','bloqueado')),
  criado_em timestamptz not null default now()
);

-- O PRIMEIRO usuário criado vira admin. Os seguintes entram como 'bloqueado'
-- até você liberar (passo 8). Assim, ninguém de fora enxerga os dados.
create or replace function public.novo_usuario() returns trigger
language plpgsql security definer set search_path = public as $f$
begin
  insert into public.perfis(user_id, nome, papel)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'nome', split_part(new.email,'@',1)),
          case when exists (select 1 from public.perfis) then 'bloqueado' else 'admin' end);
  return new;
end $f$;

drop trigger if exists ao_criar_usuario on auth.users;
create trigger ao_criar_usuario after insert on auth.users
  for each row execute function public.novo_usuario();

create or replace function public.papel_atual() returns text
language sql stable security definer set search_path = public as $f$
  select papel from public.perfis where user_id = auth.uid()
$f$;
create or replace function public.eh_autorizado() returns boolean
language sql stable security definer set search_path = public as $f$
  select coalesce(public.papel_atual() in ('admin','leitura'), false)
$f$;
create or replace function public.eh_admin() returns boolean
language sql stable security definer set search_path = public as $f$
  select coalesce(public.papel_atual() = 'admin', false)
$f$;

-- 3) CONFIGURAÇÕES PRIVADAS (token do Telegram). Ninguém pelo site consegue ler.
create table if not exists public.app_config (
  chave text primary key,
  valor text not null
);
alter table public.app_config enable row level security;   -- sem políticas = fechado
insert into public.app_config(chave, valor) values
  ('telegram_token',    '8628884766:AAGJHRoelEX2vM1tACQ2luJkDVOmFQhx1Tg'),
  ('telegram_chat_ids', '7694564020')
on conflict (chave) do nothing;

-- 4) TABELAS PRINCIPAIS (sem horário: só a data)
create table if not exists public.abastecimentos (
  id          uuid primary key default gen_random_uuid(),
  numero      integer generated always as identity,
  data        date not null,
  pessoa      text not null check (length(trim(pessoa)) > 0),
  veiculo     text not null check (length(trim(veiculo)) > 0),
  placa       text,
  valor       numeric(14,2) not null check (valor > 0),
  observacoes text,
  cancelado   boolean not null default false,
  criado_em   timestamptz not null default now(),
  criado_por  uuid default auth.uid()
);

create table if not exists public.pagamentos (
  id             uuid primary key default gen_random_uuid(),
  chave          uuid not null unique,          -- impede pagamento duplicado
  data           date not null,
  valor          numeric(14,2) not null check (valor > 0),
  forma          text not null check (forma in ('Pix','Dinheiro','Transferência')),
  observacao     text,
  estornado      boolean not null default false,
  estornado_em   timestamptz,
  motivo_estorno text,
  criado_em      timestamptz not null default now(),
  criado_por     uuid default auth.uid()
);

-- Como cada pagamento foi distribuído entre os abastecimentos (FIFO)
create table if not exists public.alocacoes (
  id               uuid primary key default gen_random_uuid(),
  pagamento_id     uuid not null references public.pagamentos(id)     on delete restrict,
  abastecimento_id uuid not null references public.abastecimentos(id) on delete restrict,
  valor            numeric(14,2) not null check (valor > 0),
  criado_em        timestamptz not null default now()
);
create index if not exists ix_aloc_abast on public.alocacoes(abastecimento_id);
create index if not exists ix_aloc_pag   on public.alocacoes(pagamento_id);
create index if not exists ix_abast_data on public.abastecimentos(data, criado_em);

-- Registro de tudo que foi criado/alterado (auditoria)
create table if not exists public.historico (
  id          bigint generated always as identity primary key,
  tabela      text not null,
  registro_id uuid not null,
  acao        text not null,
  antes       jsonb,
  depois      jsonb,
  usuario     uuid default auth.uid(),
  criado_em   timestamptz not null default now()
);
create index if not exists ix_hist_reg on public.historico(registro_id);

create or replace function public.auditar() returns trigger
language plpgsql security definer set search_path = public as $f$
begin
  insert into public.historico(tabela, registro_id, acao, antes, depois)
  values (tg_table_name, coalesce(new.id, old.id), tg_op,
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return coalesce(new, old);
end $f$;

drop trigger if exists aud_abast on public.abastecimentos;
create trigger aud_abast after insert or update or delete on public.abastecimentos
  for each row execute function public.auditar();
drop trigger if exists aud_pag on public.pagamentos;
create trigger aud_pag after insert or update or delete on public.pagamentos
  for each row execute function public.auditar();

-- 5) VISÃO COM OS SALDOS (pago, pendente e situação de cada abastecimento)
create or replace view public.v_abastecimentos with (security_invoker = true) as
select a.*,
       coalesce(p.pago, 0)                 as pago,
       a.valor - coalesce(p.pago, 0)       as pendente,
       case when a.cancelado                  then 'cancelado'
            when coalesce(p.pago,0) >= a.valor then 'pago'
            when coalesce(p.pago,0) > 0        then 'parcial'
            else 'pendente' end            as situacao
from public.abastecimentos a
left join lateral (
  select sum(al.valor) as pago
  from public.alocacoes al
  join public.pagamentos pg on pg.id = al.pagamento_id
  where al.abastecimento_id = a.id and not pg.estornado
) p on true;

-- 6) SEGURANÇA: o site só LÊ as tabelas; toda escrita passa pelas funções abaixo
alter table public.perfis          enable row level security;
alter table public.abastecimentos  enable row level security;
alter table public.pagamentos      enable row level security;
alter table public.alocacoes       enable row level security;
alter table public.historico       enable row level security;

drop policy if exists ler_perfil  on public.perfis;
create policy ler_perfil  on public.perfis         for select to authenticated using (user_id = auth.uid());
drop policy if exists ler_abast   on public.abastecimentos;
create policy ler_abast   on public.abastecimentos for select to authenticated using (public.eh_autorizado());
drop policy if exists ler_pag     on public.pagamentos;
create policy ler_pag     on public.pagamentos     for select to authenticated using (public.eh_autorizado());
drop policy if exists ler_aloc    on public.alocacoes;
create policy ler_aloc    on public.alocacoes      for select to authenticated using (public.eh_autorizado());
drop policy if exists ler_hist    on public.historico;
create policy ler_hist    on public.historico      for select to authenticated using (public.eh_autorizado());

-- 7) FUNÇÕES (toda a regra financeira é validada AQUI, não no navegador)
create or replace function public.brl(v numeric) returns text
language sql immutable as $f$
  select 'R$ ' || translate(to_char(v, 'FM999,999,999,990.00'), ',.', '.,')
$f$;

create or replace function public.saldo_pendente() returns numeric
language sql stable security definer set search_path = public as $f$
  select coalesce(sum(pendente), 0) from public.v_abastecimentos where not cancelado
$f$;

-- Envia mensagem ao Telegram (sem derrubar a operação se o Telegram falhar)
create or replace function public.enviar_telegram(p_texto text) returns void
language plpgsql security definer set search_path = public as $f$
declare v_token text; v_ids text; v_id text;
begin
  select valor into v_token from public.app_config where chave = 'telegram_token';
  select valor into v_ids   from public.app_config where chave = 'telegram_chat_ids';
  if v_token is null or v_ids is null or v_token like 'COLE%' or v_ids like 'COLE%' then return; end if;
  foreach v_id in array string_to_array(v_ids, ',') loop
    perform net.http_post(
      url     := 'https://api.telegram.org/bot' || v_token || '/sendMessage',
      body    := jsonb_build_object('chat_id', trim(v_id), 'text', p_texto),
      headers := '{"Content-Type":"application/json"}'::jsonb);
  end loop;
exception when others then
  null;
end $f$;

-- NOVO ABASTECIMENTO
create or replace function public.registrar_abastecimento(
  p_data date, p_pessoa text, p_veiculo text, p_placa text, p_valor numeric, p_obs text)
returns uuid language plpgsql security definer set search_path = public as $f$
declare v_id uuid; v_num int;
begin
  if not public.eh_admin() then raise exception 'Aviso: você não tem permissão para registrar.'; end if;
  perform pg_advisory_xact_lock(7001);
  if p_data is null then raise exception 'Aviso: informe a data do abastecimento.'; end if;
  if trim(coalesce(p_pessoa,'')) = '' or trim(coalesce(p_veiculo,'')) = '' then
    raise exception 'Aviso: informe a pessoa e o veículo.'; end if;
  if p_valor is null or p_valor <= 0 then raise exception 'Aviso: informe um valor maior que zero.'; end if;

  insert into public.abastecimentos(data, pessoa, veiculo, placa, valor, observacoes)
  values (p_data, trim(p_pessoa), trim(p_veiculo), nullif(upper(trim(coalesce(p_placa,''))),''),
          round(p_valor,2), nullif(trim(coalesce(p_obs,'')),''))
  returning id, numero into v_id, v_num;

  perform public.enviar_telegram(
    E'⛽ NOVO ABASTECIMENTO\n\nPessoa: ' || trim(p_pessoa) ||
    E'\nVeículo: ' || trim(p_veiculo) ||
    case when nullif(trim(coalesce(p_placa,'')),'') is not null then ' (' || upper(trim(p_placa)) || ')' else '' end ||
    E'\nData: ' || to_char(p_data,'DD/MM/YYYY') ||
    E'\nValor: ' || public.brl(round(p_valor,2)) ||
    E'\nSituação: Pendente\n\nTotal pendente atualizado: ' || public.brl(public.saldo_pendente()) || '.');
  return v_id;
end $f$;

-- CORRIGIR ABASTECIMENTO (o histórico guarda o antes e o depois)
create or replace function public.editar_abastecimento(
  p_id uuid, p_data date, p_pessoa text, p_veiculo text, p_placa text, p_valor numeric, p_obs text)
returns void language plpgsql security definer set search_path = public as $f$
declare v_pago numeric; v_a public.abastecimentos;
begin
  if not public.eh_admin() then raise exception 'Aviso: você não tem permissão para editar.'; end if;
  perform pg_advisory_xact_lock(7001);
  select * into v_a from public.abastecimentos where id = p_id for update;
  if not found then raise exception 'Aviso: abastecimento não encontrado.'; end if;
  if v_a.cancelado then raise exception 'Aviso: este abastecimento está cancelado.'; end if;
  if p_data is null or trim(coalesce(p_pessoa,'')) = '' or trim(coalesce(p_veiculo,'')) = '' then
    raise exception 'Aviso: preencha data, pessoa e veículo.'; end if;
  if p_valor is null or p_valor <= 0 then raise exception 'Aviso: informe um valor maior que zero.'; end if;
  select coalesce(sum(al.valor),0) into v_pago
    from public.alocacoes al join public.pagamentos pg on pg.id = al.pagamento_id
   where al.abastecimento_id = p_id and not pg.estornado;
  if round(p_valor,2) < v_pago then
    raise exception 'Aviso: este abastecimento já recebeu % em pagamentos. O valor não pode ser menor que isso.', public.brl(v_pago);
  end if;
  update public.abastecimentos
     set data = p_data, pessoa = trim(p_pessoa), veiculo = trim(p_veiculo),
         placa = nullif(upper(trim(coalesce(p_placa,''))),''), valor = round(p_valor,2),
         observacoes = nullif(trim(coalesce(p_obs,'')),'')
   where id = p_id;
  perform public.enviar_telegram(
    E'✏️ ABASTECIMENTO CORRIGIDO\n\nAbastecimento nº ' || v_a.numero || ' (' || trim(p_pessoa) || E')\nValor: ' ||
    public.brl(round(p_valor,2)) || E'\n\nSaldo pendente atualizado: ' || public.brl(public.saldo_pendente()) || '.');
end $f$;

-- CANCELAR ABASTECIMENTO (o registro nunca é apagado; só se não houver pagamento ativo)
create or replace function public.cancelar_abastecimento(p_id uuid) returns void
language plpgsql security definer set search_path = public as $f$
declare v_a public.abastecimentos;
begin
  if not public.eh_admin() then raise exception 'Aviso: você não tem permissão.'; end if;
  perform pg_advisory_xact_lock(7001);
  select * into v_a from public.abastecimentos where id = p_id for update;
  if not found then raise exception 'Aviso: abastecimento não encontrado.'; end if;
  if exists (select 1 from public.alocacoes al join public.pagamentos pg on pg.id = al.pagamento_id
              where al.abastecimento_id = p_id and not pg.estornado) then
    raise exception 'Aviso: este abastecimento já recebeu pagamento. Estorne o pagamento primeiro.';
  end if;
  update public.abastecimentos set cancelado = true where id = p_id;
  perform public.enviar_telegram(
    E'🚫 ABASTECIMENTO CANCELADO\n\nAbastecimento nº ' || v_a.numero || ' (' || v_a.pessoa || ', ' ||
    public.brl(v_a.valor) || E')\n\nSaldo pendente atualizado: ' || public.brl(public.saldo_pendente()) || '.');
end $f$;

-- REGISTRAR PAGAMENTO COM BAIXA AUTOMÁTICA (FIFO: do mais antigo para o mais novo)
create or replace function public.registrar_pagamento(
  p_chave uuid, p_data date, p_valor numeric, p_forma text, p_obs text)
returns jsonb language plpgsql security definer set search_path = public as $f$
declare
  v_pg uuid; v_total numeric; v_rest numeric; v_aloc numeric; r record;
  v_q int := 0; v_p int := 0; v_n int := 0; v_txt text := '';
begin
  if not public.eh_admin() then raise exception 'Aviso: você não tem permissão para registrar pagamentos.'; end if;
  perform pg_advisory_xact_lock(7001);              -- um pagamento por vez

  -- Já processado antes? (clique duplicado / falha de conexão) -> não baixa de novo
  select id into v_pg from public.pagamentos where chave = p_chave;
  if found then
    return jsonb_build_object('pagamento_id', v_pg, 'repetido', true,
                              'saldo_pendente', public.saldo_pendente());
  end if;

  if p_data is null then raise exception 'Aviso: informe a data do pagamento.'; end if;
  if p_valor is null or round(p_valor,2) <= 0 then raise exception 'Aviso: informe um valor maior que zero.'; end if;
  if p_forma not in ('Pix','Dinheiro','Transferência') then raise exception 'Aviso: forma de pagamento inválida.'; end if;

  v_total := public.saldo_pendente();
  if round(p_valor,2) > v_total then
    raise exception 'Aviso: o pagamento (%) é maior que a dívida total (%). Informe no máximo %.',
      public.brl(round(p_valor,2)), public.brl(v_total), public.brl(v_total);
  end if;

  insert into public.pagamentos(chave, data, valor, forma, observacao)
  values (p_chave, p_data, round(p_valor,2), p_forma, nullif(trim(coalesce(p_obs,'')),''))
  returning id into v_pg;

  v_rest := round(p_valor,2);
  for r in select id, numero, data, pessoa, pendente from public.v_abastecimentos
            where not cancelado and pendente > 0
            order by data, criado_em, id loop
    exit when v_rest <= 0;
    v_aloc := least(v_rest, r.pendente);
    insert into public.alocacoes(pagamento_id, abastecimento_id, valor) values (v_pg, r.id, v_aloc);
    v_rest := v_rest - v_aloc;
    v_n := v_n + 1;
    if v_aloc = r.pendente then
      v_q := v_q + 1;
      if v_n <= 10 then v_txt := v_txt || E'\n✅ ' || to_char(r.data,'DD/MM') || ' ' || r.pessoa || ': quitado'; end if;
    else
      v_p := v_p + 1;
      if v_n <= 10 then v_txt := v_txt || E'\n⚠️ ' || to_char(r.data,'DD/MM') || ' ' || r.pessoa ||
                          ': parcial, ainda falta ' || public.brl(r.pendente - v_aloc); end if;
    end if;
  end loop;

  if v_rest <> 0 then raise exception 'Erro interno: sobrou valor sem distribuir. Operação desfeita.'; end if;

  perform public.enviar_telegram(
    E'💰 PAGAMENTO REGISTRADO\n\nValor recebido: ' || public.brl(round(p_valor,2)) ||
    E'\nForma: ' || p_forma ||
    E'\nAbastecimentos quitados: ' || v_q ||
    E'\nAbastecimentos parcialmente pagos: ' || v_p || v_txt ||
    E'\n\nSaldo pendente total: ' || public.brl(public.saldo_pendente()) || '.');

  return jsonb_build_object('pagamento_id', v_pg, 'repetido', false, 'quitados', v_q,
                            'parciais', v_p, 'saldo_pendente', public.saldo_pendente());
end $f$;

-- ESTORNAR PAGAMENTO (os valores voltam a ficar pendentes; o registro continua no histórico)
create or replace function public.estornar_pagamento(p_id uuid, p_motivo text default null)
returns numeric language plpgsql security definer set search_path = public as $f$
declare v_p public.pagamentos;
begin
  if not public.eh_admin() then raise exception 'Aviso: você não tem permissão.'; end if;
  perform pg_advisory_xact_lock(7001);
  select * into v_p from public.pagamentos where id = p_id for update;
  if not found then raise exception 'Aviso: pagamento não encontrado.'; end if;
  if v_p.estornado then raise exception 'Aviso: este pagamento já foi estornado.'; end if;
  update public.pagamentos
     set estornado = true, estornado_em = now(), motivo_estorno = nullif(trim(coalesce(p_motivo,'')),'')
   where id = p_id;
  perform public.enviar_telegram(
    E'↩️ PAGAMENTO ESTORNADO\n\nValor estornado: ' || public.brl(v_p.valor) ||
    E' (pagamento de ' || to_char(v_p.data,'DD/MM/YYYY') || E')\n\nSaldo pendente total: ' ||
    public.brl(public.saldo_pendente()) || '.');
  return public.saldo_pendente();
end $f$;

-- Aviso de erro importante (o site chama quando um pagamento falha por motivo inesperado)
create or replace function public.notificar_erro(p_msg text) returns void
language plpgsql security definer set search_path = public as $f$
begin
  if not public.eh_admin() then return; end if;
  perform public.enviar_telegram(E'🚨 ERRO NO PROCESSAMENTO DO PAGAMENTO\n\n' || left(coalesce(p_msg,'sem detalhes'), 300) ||
    E'\n\nConfira a lista de Pagamentos antes de tentar de novo.');
end $f$;

create or replace function public.testar_telegram() returns void
language plpgsql security definer set search_path = public as $f$
begin
  if not public.eh_admin() then raise exception 'Aviso: você não tem permissão.'; end if;
  perform public.enviar_telegram('✅ Teste: o aviso do Telegram está funcionando.');
end $f$;

-- 7B) BOT DO TELEGRAM COM COMANDOS (/abastecimento, /pagamento, /status, /pendentes, /ultimos)
-- A conversa passa pela Edge Function 'telegram-bot' (veja o passo E no final).

-- 7B.1) Configurações novas
-- telegram_admins: IDs que podem REGISTRAR pelo bot (separe por vírgula).
-- Enquanto ficar "COLE...", todos os IDs de telegram_chat_ids podem registrar.
insert into public.app_config(chave, valor) values
  ('telegram_admins', 'COLE_AQUI_OS_IDS_QUE_PODEM_REGISTRAR'),
  ('telegram_webhook_secret', replace(gen_random_uuid()::text, '-', ''))
on conflict (chave) do nothing;

-- 7B.2) Conversa em andamento de cada chat
create table if not exists public.bot_sessoes (
  chat_id text primary key, fluxo text, passo text,
  dados jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now());
alter table public.bot_sessoes enable row level security;
revoke all on public.bot_sessoes from anon, authenticated;

-- 7B.3) Ajudantes
create or replace function public.hoje_br() returns date language sql stable as $f$
  select (now() at time zone 'America/Rio_Branco')::date $f$;   -- troque o fuso aqui se precisar

create or replace function public._r(t text, b jsonb default null) returns jsonb
language sql immutable as $f$ select jsonb_build_object('t', t, 'b', coalesce(b, '[]'::jsonb)) $f$;

create or replace function public._bot_num(s text) returns numeric language plpgsql immutable as $f$
begin
  s := regexp_replace(coalesce(s,''), '[R$\s]', '', 'g');
  if s = '' then return null; end if;
  if position(',' in s) > 0 then s := replace(replace(s,'.',''),',','.');
  elsif s !~ '^\d+\.\d{1,2}$' then s := replace(s,'.',''); end if;
  if s !~ '^\d+(\.\d+)?$' then return null; end if;
  return round(s::numeric, 2);
exception when others then return null;
end $f$;

create or replace function public._bot_data(t text) returns date language plpgsql stable as $f$
declare m text[]; y int;
begin
  t := lower(trim(coalesce(t,'')));
  if t in ('#hoje','hoje') then return public.hoje_br(); end if;
  if t in ('#ontem','ontem') then return public.hoje_br() - 1; end if;
  m := regexp_match(t, '^(\d{1,2})[/.-](\d{1,2})(?:[/.-](\d{2,4}))?$');
  if m is null then return null; end if;
  y := coalesce(nullif(m[3],'')::int, extract(year from public.hoje_br())::int);
  if y < 100 then y := y + 2000; end if;
  return make_date(y, m[2]::int, m[1]::int);
exception when others then return null;
end $f$;

-- 7B.4) Textos dos comandos de consulta
create or replace function public._bot_status() returns text
language plpgsql security definer set search_path = public as $f$
declare t numeric; p numeric; q numeric; n int; np int; nl int; ng int;
        ma numeric; mp numeric; a record; u record; r record; top text := '';
begin
  select coalesce(sum(valor),0), coalesce(sum(pago),0), coalesce(sum(pendente),0), count(*),
         count(*) filter (where situacao='pendente'), count(*) filter (where situacao='parcial'),
         count(*) filter (where situacao='pago')
    into t, p, q, n, np, nl, ng from public.v_abastecimentos where not cancelado;
  select coalesce(sum(valor),0) into ma from public.abastecimentos
   where not cancelado and date_trunc('month', data) = date_trunc('month', public.hoje_br());
  select coalesce(sum(valor),0) into mp from public.pagamentos
   where not estornado and date_trunc('month', data) = date_trunc('month', public.hoje_br());
  select data, pessoa, pendente into a from public.v_abastecimentos
   where not cancelado and pendente > 0 order by data, criado_em limit 1;
  select data, valor into u from public.pagamentos where not estornado order by data desc, criado_em desc limit 1;
  for r in select pessoa, sum(pendente) s from public.v_abastecimentos
            where not cancelado and pendente > 0 group by pessoa order by 2 desc limit 3 loop
    top := top || E'\n• ' || r.pessoa || ': ' || public.brl(r.s);
  end loop;
  return E'📊 STATUS GERAL\n\n💰 Falta pagar: ' || public.brl(q) ||
    E'\n⛽ Total abastecido: ' || public.brl(t) || ' (' || n || E' abastecimentos)' ||
    E'\n✅ Total pago: ' || public.brl(p) || ' (' || case when t > 0 then round(p / t * 100) else 0 end || E'%)' ||
    E'\n\n🟡 Pendentes: ' || np || E'  🔵 Parciais: ' || nl || E'  🟢 Pagos: ' || ng ||
    E'\n\n📆 Neste mês: abastecido ' || public.brl(ma) || ', pago ' || public.brl(mp) ||
    case when a.data is not null then E'\n⏳ Mais antigo em aberto: ' || to_char(a.data,'DD/MM/YYYY') ||
         ' (' || a.pessoa || ', falta ' || public.brl(a.pendente) || ')' else '' end ||
    case when u.data is not null then E'\n💳 Último pagamento: ' || public.brl(u.valor) || ' em ' || to_char(u.data,'DD/MM/YYYY') else '' end ||
    case when top <> '' then E'\n\n🏆 Maiores saldos pendentes:' || top else '' end;
end $f$;

create or replace function public._bot_pendentes() returns text
language plpgsql security definer set search_path = public as $f$
declare r record; t text := ''; tot int;
begin
  select count(*) into tot from public.v_abastecimentos where not cancelado and pendente > 0;
  if tot = 0 then return '🎉 Nada pendente. Tudo pago!'; end if;
  for r in select * from public.v_abastecimentos where not cancelado and pendente > 0 order by data, criado_em limit 10 loop
    t := t || E'\n' || case r.situacao when 'parcial' then '🔵 ' else '🟡 ' end ||
         to_char(r.data,'DD/MM') || ' ' || r.pessoa || ' (' || r.veiculo || '): ' || public.brl(r.pendente);
  end loop;
  return E'🧾 PENDENTES (mais antigos primeiro)\n' || t ||
    case when tot > 10 then E'\n\n... e mais ' || (tot - 10) || ' abastecimentos.' else '' end ||
    E'\n\nTotal pendente: ' || public.brl(public.saldo_pendente()) || '.';
end $f$;

create or replace function public._bot_ultimos() returns text
language plpgsql security definer set search_path = public as $f$
declare r record; t text := E'⛽ ÚLTIMOS ABASTECIMENTOS\n'; p text := '';
begin
  for r in select * from public.v_abastecimentos where not cancelado order by data desc, criado_em desc limit 5 loop
    t := t || E'\n' || case r.situacao when 'pago' then '✅ ' when 'parcial' then '🔵 ' else '🟡 ' end ||
         to_char(r.data,'DD/MM') || ' ' || r.pessoa || ' (' || r.veiculo || '): ' || public.brl(r.valor);
  end loop;
  for r in select * from public.pagamentos where not estornado order by data desc, criado_em desc limit 3 loop
    p := p || E'\n💳 ' || to_char(r.data,'DD/MM') || ' ' || public.brl(r.valor) || ' (' || r.forma || ')';
  end loop;
  return t || case when p <> '' then E'\n\nÚLTIMOS PAGAMENTOS' || p else '' end;
end $f$;

-- 7B.5) Perguntas de cada passo (texto + botões)
create or replace function public._bot_pergunta(p_fluxo text, p_passo text, d jsonb) returns jsonb
language plpgsql security definer set search_path = public as $f$
declare b jsonb := '[]'::jsonb; r record; v text; txt text; pend numeric;
begin
  if p_passo = 'pessoa' then
    for r in select pessoa x from public.abastecimentos where not cancelado group by pessoa order by max(criado_em) desc limit 6 loop
      b := b || jsonb_build_array(jsonb_build_array(left(r.x,30), left(r.x,30))); end loop;
    txt := E'⛽ NOVO ABASTECIMENTO\n\nQuem abasteceu? Toque no nome ou digite.';
  elsif p_passo = 'veiculo' then
    for r in select veiculo x from public.abastecimentos where not cancelado group by veiculo
              order by bool_or(pessoa = d->>'pessoa') desc, max(criado_em) desc limit 6 loop
      b := b || jsonb_build_array(jsonb_build_array(left(r.x,30), left(r.x,30))); end loop;
    txt := 'Qual o veículo? Toque ou digite.';
  elsif p_passo = 'placa' then
    select placa into v from public.abastecimentos where veiculo = d->>'veiculo' and placa is not null order by criado_em desc limit 1;
    if v is not null then b := b || jsonb_build_array(jsonb_build_array('Usar ' || v, v)); end if;
    b := b || jsonb_build_array(jsonb_build_array('Pular', '#pular'));
    txt := 'Qual a placa? (opcional)';
  elsif p_passo = 'valor' and p_fluxo = 'abast' then
    txt := 'Qual o valor total? Ex.: 150,00';
  elsif p_passo = 'valor' then
    pend := public.saldo_pendente();
    b := b || jsonb_build_array(jsonb_build_array('Pagar tudo (' || public.brl(pend) || ')', '#tudo'));
    txt := E'💰 REGISTRAR PAGAMENTO\n\nFalta pagar: ' || public.brl(pend) || E'\nQual o valor recebido? Ex.: 500,00';
  elsif p_passo = 'forma' then
    b := jsonb_build_array(jsonb_build_array('Pix','Pix'), jsonb_build_array('Dinheiro','Dinheiro'), jsonb_build_array('Transferência','Transferência'));
    txt := 'Qual a forma de pagamento?';
  elsif p_passo = 'data' then
    b := jsonb_build_array(jsonb_build_array('Hoje','#hoje'), jsonb_build_array('Ontem','#ontem'));
    txt := 'Qual a data? Toque ou digite, ex.: 25/09';
  elsif p_passo = 'obs' then
    b := jsonb_build_array(jsonb_build_array('Pular','#pular'));
    txt := 'Alguma observação? (opcional)';
  elsif p_fluxo = 'abast' then   -- conf
    txt := E'📝 Confira antes de salvar:\n\n👤 ' || (d->>'pessoa') || E'\n🚚 ' || (d->>'veiculo') ||
      coalesce(' (' || (d->>'placa') || ')', '') || E'\n📅 ' || to_char((d->>'data')::date,'DD/MM/YYYY') ||
      E'\n💵 ' || public.brl((d->>'valor')::numeric) || coalesce(E'\n📝 ' || (d->>'obs'), '');
    b := jsonb_build_array(jsonb_build_array('✅ Confirmar','#ok'));
  else
    txt := E'📝 Confira o pagamento:\n\n💵 ' || public.brl((d->>'valor')::numeric) || E'\n💳 ' || (d->>'forma') ||
      E'\n📅 ' || to_char((d->>'data')::date,'DD/MM/YYYY') || coalesce(E'\n📝 ' || (d->>'obs'), '') ||
      E'\n\nSerá abatido dos abastecimentos mais antigos primeiro. Falta pagar depois: ' ||
      public.brl(public.saldo_pendente() - (d->>'valor')::numeric) || '.';
    b := jsonb_build_array(jsonb_build_array('✅ Confirmar','#ok'));
  end if;
  return public._r(txt, b || jsonb_build_array(jsonb_build_array('❌ Cancelar','#cancelar')));
end $f$;

-- 7B.6) O cérebro do bot: recebe (chat, texto) e devolve a resposta
create or replace function public.bot_processar(p_chat text, p_texto text) returns jsonb
language plpgsql security definer set search_path = public as $f$
declare
  v_ids text; v_adm text; v_eadm boolean; v_t text := trim(coalesce(p_texto,'')); v_c text;
  v_s public.bot_sessoes; v_d jsonb; v_n numeric; v_dt date; v_uid uuid; v_id uuid; v_i int;
  v_x jsonb; v_txt text; v_next text;
begin
  select valor into v_ids from public.app_config where chave = 'telegram_chat_ids';
  if v_ids is null or not (p_chat = any(string_to_array(replace(v_ids,' ',''), ','))) then
    return public._r(E'🔒 Este chat não tem acesso ao bot.\nID deste chat: ' || p_chat);
  end if;
  select valor into v_adm from public.app_config where chave = 'telegram_admins';
  v_eadm := case when coalesce(trim(v_adm),'') = '' or v_adm like 'COLE%' then true
                 else p_chat = any(string_to_array(replace(v_adm,' ',''), ',')) end;
  v_c := split_part(lower(split_part(v_t,' ',1)), '@', 1);
  select * into v_s from public.bot_sessoes where chat_id = p_chat;

  -- comandos
  if v_c in ('/start','/ajuda','/help') then
    return public._r(E'🤖 CONTROLE DE ABASTECIMENTOS\n\n/status - resumo geral\n/pendentes - o que falta pagar\n/ultimos - últimos registros' ||
      case when v_eadm then E'\n/abastecimento - registrar um abastecimento (eu pergunto tudo)\n/pagamento - registrar um pagamento'
           else E'\n\n(Este chat é só de consulta.)' end || E'\n/cancelar - cancelar o que estiver em andamento');
  elsif v_c = '/status' then return public._r(public._bot_status());
  elsif v_c = '/pendentes' then return public._r(public._bot_pendentes());
  elsif v_c = '/ultimos' then return public._r(public._bot_ultimos());
  elsif v_c = '/cancelar' or v_t = '#cancelar' then
    delete from public.bot_sessoes where chat_id = p_chat;
    return public._r('Ok, cancelado. Toque em /ajuda para ver os comandos.');
  elsif v_c in ('/abastecimento','/pagamento') then
    if not v_eadm then return public._r('🔒 Este chat é só de consulta. Use /status, /pendentes ou /ultimos.'); end if;
    if v_c = '/pagamento' and public.saldo_pendente() <= 0 then return public._r('🎉 Não há nada pendente para pagar.'); end if;
    v_txt := case when v_c = '/pagamento' then 'pag' else 'abast' end;
    v_d := case when v_txt = 'pag' then jsonb_build_object('chave', gen_random_uuid()) else '{}'::jsonb end;
    v_next := case when v_txt = 'pag' then 'valor' else 'pessoa' end;
    insert into public.bot_sessoes(chat_id, fluxo, passo, dados) values (p_chat, v_txt, v_next, v_d)
    on conflict (chat_id) do update set fluxo = excluded.fluxo, passo = excluded.passo, dados = excluded.dados, atualizado_em = now();
    return public._bot_pergunta(v_txt, v_next, v_d);
  elsif left(v_t,1) = '/' then
    return public._r('Não conheci esse comando. Toque em /ajuda.');
  end if;

  -- resposta a uma pergunta do bot
  if v_s.fluxo is null then
    return public._r('Nada em andamento. Use /abastecimento, /pagamento ou /status.');
  end if;
  if v_s.atualizado_em < now() - interval '30 minutes' then
    delete from public.bot_sessoes where chat_id = p_chat;
    return public._r('Essa conversa expirou. Comece de novo com /abastecimento ou /pagamento.');
  end if;
  v_d := v_s.dados;

  if v_s.passo in ('pessoa','veiculo') then
    if v_t = '' or length(v_t) > 60 then return public._r('Digite um nome válido.', public._bot_pergunta(v_s.fluxo, v_s.passo, v_d)->'b'); end if;
    if v_s.passo = 'pessoa' then
      select pessoa into v_txt from public.abastecimentos where lower(pessoa) = lower(v_t) limit 1;
      v_d := v_d || jsonb_build_object('pessoa', coalesce(v_txt, v_t)); v_next := 'veiculo';
    else
      select veiculo into v_txt from public.abastecimentos where lower(veiculo) = lower(v_t) limit 1;
      v_d := v_d || jsonb_build_object('veiculo', coalesce(v_txt, v_t)); v_next := 'placa';
    end if;
  elsif v_s.passo = 'placa' then
    v_d := case when lower(v_t) in ('#pular','pular') then v_d - 'placa' else v_d || jsonb_build_object('placa', upper(left(v_t,10))) end;
    v_next := 'valor';
  elsif v_s.passo = 'valor' then
    v_n := case when v_t = '#tudo' and v_s.fluxo = 'pag' then public.saldo_pendente() else public._bot_num(v_t) end;
    if v_n is null or v_n <= 0 then return public._r('Não entendi o valor. Digite assim: 150,00', public._bot_pergunta(v_s.fluxo, 'valor', v_d)->'b'); end if;
    if v_s.fluxo = 'pag' and v_n > public.saldo_pendente() then
      return public._r('O valor é maior que a dívida total (' || public.brl(public.saldo_pendente()) || '). Digite um valor menor.', public._bot_pergunta('pag','valor',v_d)->'b'); end if;
    v_d := v_d || jsonb_build_object('valor', v_n); v_next := case when v_s.fluxo = 'pag' then 'forma' else 'data' end;
  elsif v_s.passo = 'forma' then
    v_txt := case lower(v_t) when 'pix' then 'Pix' when 'dinheiro' then 'Dinheiro' when 'transferência' then 'Transferência' when 'transferencia' then 'Transferência' end;
    if v_txt is null then return public._r('Escolha: Pix, Dinheiro ou Transferência.', public._bot_pergunta('pag','forma',v_d)->'b'); end if;
    v_d := v_d || jsonb_build_object('forma', v_txt); v_next := 'data';
  elsif v_s.passo = 'data' then
    v_dt := public._bot_data(v_t);
    if v_dt is null or v_dt > public.hoje_br() then
      return public._r('Não entendi a data (não pode ser futura). Ex.: 25/09 ou 25/09/2026.', public._bot_pergunta(v_s.fluxo,'data',v_d)->'b'); end if;
    v_d := v_d || jsonb_build_object('data', v_dt); v_next := 'obs';
  elsif v_s.passo = 'obs' then
    v_d := case when lower(v_t) in ('#pular','pular') then v_d - 'obs' else v_d || jsonb_build_object('obs', left(v_t,200)) end;
    v_next := 'conf';
  elsif v_s.passo = 'conf' then
    if v_t <> '#ok' then return public._bot_pergunta(v_s.fluxo, 'conf', v_d); end if;
    -- age como o primeiro usuário admin, para as regras de permissão e o histórico funcionarem
    select user_id into v_uid from public.perfis where papel = 'admin' order by criado_em limit 1;
    if v_uid is null then return public._r('⚠️ Nenhum usuário admin cadastrado no site.'); end if;
    perform set_config('request.jwt.claim.sub', v_uid::text, true);
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
    begin
      if v_s.fluxo = 'abast' then
        v_id := public.registrar_abastecimento((v_d->>'data')::date, v_d->>'pessoa', v_d->>'veiculo', v_d->>'placa',
                  (v_d->>'valor')::numeric, trim(coalesce(v_d->>'obs','') || ' (via Telegram)'));
        select numero into v_i from public.abastecimentos where id = v_id;
        delete from public.bot_sessoes where chat_id = p_chat;
        return public._r(E'✅ Abastecimento nº ' || v_i || E' registrado!\n\nFalta pagar no total: ' ||
                         public.brl(public.saldo_pendente()) || E'.\n\nPara outro, toque em /abastecimento.');
      else
        v_x := public.registrar_pagamento((v_d->>'chave')::uuid, (v_d->>'data')::date, (v_d->>'valor')::numeric,
                 v_d->>'forma', trim(coalesce(v_d->>'obs','') || ' (via Telegram)'));
        delete from public.bot_sessoes where chat_id = p_chat;
        return public._r(case when (v_x->>'repetido')::boolean then '✅ Este pagamento já estava registrado. Nada foi cobrado de novo.'
          else E'✅ Pagamento registrado!\n\nQuitados: ' || (v_x->>'quitados') || E'  Parciais: ' || (v_x->>'parciais') end ||
          E'\nFalta pagar: ' || public.brl((v_x->>'saldo_pendente')::numeric) || '.');
      end if;
    exception when others then
      return public._r('⚠️ ' || regexp_replace(sqlerrm, '^Aviso:\s*', ''), public._bot_pergunta(v_s.fluxo,'conf',v_d)->'b');
    end;
  end if;

  update public.bot_sessoes set passo = v_next, dados = v_d, atualizado_em = now() where chat_id = p_chat;
  return public._bot_pergunta(v_s.fluxo, v_next, v_d);
end $f$;

-- 7B.7) Atualização em tempo real no site (o site se atualiza quando o bot registra algo)
do $$ begin
  begin alter publication supabase_realtime add table public.abastecimentos; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.pagamentos;     exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.alocacoes;      exception when duplicate_object then null; end;
end $$;

-- 8) PERMISSÕES FINAIS (fecha tudo e libera só o necessário)
revoke all on all tables in schema public from anon, authenticated;
grant select on public.perfis, public.abastecimentos, public.pagamentos,
                public.alocacoes, public.historico, public.v_abastecimentos to authenticated;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.papel_atual(), public.eh_autorizado(), public.eh_admin() to authenticated;
grant execute on function
  public.registrar_abastecimento(date,text,text,text,numeric,text),
  public.editar_abastecimento(uuid,date,text,text,text,numeric,text),
  public.cancelar_abastecimento(uuid),
  public.registrar_pagamento(uuid,date,numeric,text,text),
  public.estornar_pagamento(uuid,text),
  public.notificar_erro(text),
  public.testar_telegram()
to authenticated;
grant execute on function public.bot_processar(text,text) to service_role;   -- só o servidor chama o bot

-- =====================================================================
-- PASSOS MANUAIS DEPOIS DE RODAR ESTE ARQUIVO
--
-- A) Criar os usuários: Authentication > Users > Add user (e-mail + senha,
--    marque "Auto Confirm User"). O PRIMEIRO usuário criado vira admin.
--    Em Authentication > Sign In / Providers, DESLIGUE "Allow new users to sign up".
--
-- B) Liberar os demais (rode uma linha por pessoa, trocando o e-mail):
--    update public.perfis set papel = 'leitura'   -- só consulta (ex.: sua avó)
--     where user_id = (select id from auth.users where email = 'avo@email.com');
--    update public.perfis set papel = 'admin'     -- pode registrar
--     where user_id = (select id from auth.users where email = 'funcionario@email.com');
--
-- C) Telegram (rode numa consulta separada e NÃO salve essa consulta):
--    update public.app_config set valor = 'SEU_TOKEN_DO_BOTFATHER' where chave = 'telegram_token';
--    update public.app_config set valor = '111111111,222222222'     where chave = 'telegram_chat_ids';
--    (cada pessoa precisa abrir o bot e mandar /start antes de receber mensagens)
--    Se uma mensagem não chegar, veja o motivo com:
--    select status_code, content from net._http_response order by created desc limit 5;
--
-- D) Backup: Supabase > Database > Backups (diário nos planos pagos). No plano
--    gratuito, use os botões "Baixar planilha" do site toda semana.
--
-- E) BOT COM COMANDOS (depois de rodar este arquivo e de fazer o passo C):
--    1. Supabase > Edge Functions > Deploy a new function > Via Editor > nome: telegram-bot
--       Cole o arquivo telegram-bot/index.ts e faça o Deploy. Desligue "Verify JWT" nas configurações da função.
--    2. select valor from public.app_config where chave = 'telegram_webhook_secret';   (copie o segredo)
--    3. Abra no navegador (troque SEU_TOKEN e SEGREDO):
--       https://api.telegram.org/botSEU_TOKEN/setWebhook?url=https://mkzkasgaxzpynrhrgmrt.supabase.co/functions/v1/telegram-bot&secret_token=SEGREDO
--    4. Mande /start para o bot. Para deixar algum chat só com consulta, preencha telegram_admins:
--       update public.app_config set valor = 'ID1,ID2' where chave = 'telegram_admins';
-- =====================================================================
