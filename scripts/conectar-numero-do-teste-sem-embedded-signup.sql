-- CONECTAR O NUMERO DO SALAO DE TESTE SEM PASSAR PELO EMBEDDED SIGNUP.
--
-- 23/09/2026. O Embedded Signup (o fluxo do QR) existe para cadastrar o salao
-- DOS OUTROS, e a Meta so libera isso depois de aprovar Acesso Avancado em App
-- Review -- por isso a janela diz "nao pode integrar clientes no momento".
-- Processo com prazo, nao interruptor.
--
-- Para um numero SEU, dentro do SEU WABA, nada disso e necessario: basta
-- adicionar o numero no WhatsApp Manager e registrar a conexao aqui.
--
-- ============================================================
-- ANTES DE RODAR, faca estes tres passos na Meta:
-- ============================================================
--
-- 1. ADICIONAR O NUMERO
--    business.facebook.com > Configuracoes do WhatsApp Manager >
--    Numeros de telefone > Adicionar numero de telefone
--    Cadastre o 16 99412-7035 e confirme pelo codigo que chega nele.
--    ATENCAO: o numero precisa estar FORA do aplicativo WhatsApp comum e do
--    WhatsApp Business, ou a Meta recusa. Se ele ja tem WhatsApp, apague a
--    conta dele no aplicativo antes (Configuracoes > Conta > Apagar conta).
--
-- 2. ANOTAR O phone_number_id
--    Na mesma tela, o numero mostra um ID longo so de digitos. E esse que
--    entra abaixo -- NAO e o telefone com DDD.
--
-- 3. GERAR UM TOKEN DE USUARIO DO SISTEMA
--    business.facebook.com > Configuracoes do negocio > Usuarios >
--    Usuarios do sistema > (o seu) > Gerar novo token
--    App: Beauty Agent SaaS
--    Permissoes: whatsapp_business_management e whatsapp_business_messaging
--    Validade: 60 dias (ou "Nunca expira", se a tela oferecer)
--
-- ============================================================
-- O TOKEN E SEGREDO. NAO MANDE PARA A IA, NAO COLE NO CHAT.
-- Cole so aqui embaixo, na sua maquina, e rode.
-- ============================================================

select app.wa_connection_upsert(
  p_tenant_id       => 'b5634041-140a-48c6-9040-b78623c46eed',  -- Salao Teste (S-Eduarda)
  p_waba_id         => '27715432581451174',                      -- o WABA que voce ja usa
  p_phone_number_id => 'COLE_AQUI_O_PHONE_NUMBER_ID',            -- do passo 2
  p_token           => 'COLE_AQUI_O_TOKEN',                      -- do passo 3
  p_purpose         => 'CLIENTE',
  p_is_coexistence  => false,      -- numero novo na API, nao ha o que coexistir
  p_display_phone   => '+55 16 99412-7035',
  p_verified_name   => 'Salao Teste',
  p_history_state   => 'NAO_PEDIDO',
  p_actor           => 'duda@manual-23092026'
);

-- A LISTA DE PERMISSAO. Salao novo nasce com allowlist_required = true: so
-- quem esta na lista recebe resposta. Sem esta parte a sua mensagem chega,
-- e guardada, e e recusada em silencio -- o Eddy parece quebrado de novo.
insert into app.channel_allowlist (tenant_id, connection_id, normalized_contact)
select cc.tenant_id, cc.id, '5516994215487'
from app.channel_connections cc
where cc.tenant_id = 'b5634041-140a-48c6-9040-b78623c46eed'
on conflict do nothing;

-- CONFERENCIA. Tem que aparecer o numero, o modo, e voce na lista.
select cc.display_phone_number as numero_do_salao,
       cc.external_sender_id   as phone_number_id,
       cc.status, cc.mode, cc.allowlist_required,
       (cc.access_token_cipher is not null) as token_guardado,
       (select string_agg(a.normalized_contact, ', ') from app.channel_allowlist a
         where a.connection_id = cc.id and a.status = 'ACTIVE') as quem_passa,
       (select string_agg(o.phone_digits, ', ') from app.owner_whatsapp o
         where o.tenant_id = cc.tenant_id and o.status = 'ACTIVE') as dona_do_salao
from app.channel_connections cc
where cc.tenant_id = 'b5634041-140a-48c6-9040-b78623c46eed';
