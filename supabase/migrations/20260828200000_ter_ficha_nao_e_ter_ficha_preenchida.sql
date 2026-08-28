-- Ter ficha não é ter ficha preenchida.
--
-- O ERRO, meu, de lógica. Eu escrevi no prompt: "`isKnown: true` é cliente da
-- casa, NÃO pergunte de novo o que já está na ficha". O agente obedeceu direito.
-- Só que `isKnown` diz apenas que EXISTE uma ficha, não que ela tem algo
-- dentro. A ficha da Duda está com comprimento, espessura, química, cor e tom
-- todos nulos, status PRE_CADASTRO. Ele tratou ela como cliente conhecida e não
-- perguntou nada: nem foto do cabelo, nem se tem química, nem se tem tintura.
-- Foi direto oferecer horário para um procedimento químico sem saber nada do
-- cabelo de quem vai sentar na cadeira.
--
-- `isKnown` era o sinal errado. O sinal certo é POR CAMPO: preenchido, não
-- pergunta; vazio e necessário, pergunta.
--
-- E a lista do que falta não pode ser o agente olhando nulos e decidindo, por
-- dois motivos. Primeiro porque modelo lendo `null` e concluindo "então eu
-- pergunto" é frágil, e acabou de falhar. Segundo, e mais importante: QUAIS
-- campos importam é decisão do negócio, não minha. Um studio de cílios não
-- pergunta sobre formol. Então a lista sai do banco, calculada a partir da
-- ficha daquele negócio, e chega pronta no contexto como `client.missing`.
--
-- O agente não precisa saber o que cada código significa nem inventar
-- pergunta: ele recebe o rótulo, a pergunta sugerida em português, e a ordem.
-- Isso mantém o prompt genérico e deixa o conteúdo com quem é dono dele.

create or replace function app.client_profile_missing(
  p_tenant_id  uuid,
  p_profile_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
  with p as (
    select * from app.client_profiles
     where tenant_id = p_tenant_id and id = p_profile_id
  ),
  tem_foto as (
    select exists (
      select 1 from app.client_photos f
       where f.tenant_id = p_tenant_id and f.profile_id = p_profile_id
         and f.kind = 'CABELO_ATUAL'
    ) as sim
  ),
  faltas as (
    -- A ordem aqui é a ordem em que as perguntas devem sair. Foto primeiro
    -- porque uma foto responde metade das outras sozinha.
    select * from (values
      (1, 'FOTO_ATUAL',       'Manda uma foto do seu cabelo hoje, como ele está?',
          (select not sim from tem_foto)),
      (2, 'TEM_QUIMICA',      'Você já fez alguma química no cabelo?',
          (select has_chemistry is null from p)),
      (3, 'QUANDO_A_QUIMICA', 'Faz quanto tempo que você fez a última química?',
          (select coalesce(has_chemistry, false) and chemistry_last_at is null from p)),
      (4, 'QUIMICA_COM_FORMOL','Você sabe se essa química tinha formol?',
          (select coalesce(has_chemistry, false) and chemistry_formol is null from p)),
      (5, 'TEM_COLORACAO',    'Seu cabelo é colorido ou tem tintura?',
          (select has_color is null from p)),
      (6, 'QUANDO_COLORIU',   'Faz quanto tempo que você coloriu?',
          (select coalesce(has_color, false) and color_last_at is null from p)),
      (7, 'TOM_QUE_QUER',     'Tem uma foto do tom que você quer alcançar?',
          (select tone_wanted is null from p)),
      (8, 'COMPRIMENTO',      'Seu cabelo é curto, médio ou comprido?',
          (select length_option_id is null from p))
    ) as v(ordem, campo, pergunta, falta)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'campo', campo, 'perguntaSugerida', pergunta
         ) order by ordem), '[]'::jsonb)
    from faltas where falta;
$function$;

comment on function app.client_profile_missing(uuid, uuid) is
  'O que ainda falta na ficha desta cliente, na ordem em que deve ser perguntado, com a pergunta ja escrita em portugues. Existe porque `isKnown` so diz que a ficha existe: quem decide se pergunta ou nao e o campo, um por um.';

revoke all on function app.client_profile_missing(uuid, uuid) from public, anon, authenticated;
grant execute on function app.client_profile_missing(uuid, uuid) to service_role;
