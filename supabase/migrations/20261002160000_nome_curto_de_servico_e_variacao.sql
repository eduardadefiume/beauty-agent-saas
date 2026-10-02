-- "PÉ" É NOME DE SERVIÇO; "P", "M", "G" SÃO NOMES DE VARIAÇÃO.
--
-- 02/10, DEV, William-robô: "a karen faz mão 35 pé 35". O serviço "Pé" foi
-- recusado (onboarding_criar_servico exigia 3 letras) e o Eddy inventou
-- "Pé (Pedicure)", contando ao dono que "só Pé não colou no sistema".
-- Mesmo erro na variação: cabelo P/M/G (tamanho) era recusado (mínimo 2).
--
-- Serviço: mínimo 2 letras. Variação: mínimo 1. Só o trecho da validação muda.

do $m$
declare
  v_def text;
  v_novo text;
begin
  v_def := pg_get_functiondef('app.onboarding_criar_servico'::regproc);
  v_novo := replace(v_def, 'length(v_nome) < 3 or length(v_nome) > 120', 'length(v_nome) < 2 or length(v_nome) > 120');
  if v_novo = v_def then
    raise exception 'onboarding_criar_servico: trecho da validação do nome não encontrado';
  end if;
  execute v_novo;

  v_def := pg_get_functiondef('app.onboarding_criar_variacao'::regproc);
  v_novo := replace(v_def, 'length(v_nome) < 2 or length(v_nome) > 120', 'length(v_nome) < 1 or length(v_nome) > 120');
  if v_novo = v_def then
    raise exception 'onboarding_criar_variacao: trecho da validação do nome não encontrado';
  end if;
  execute v_novo;
end
$m$;
