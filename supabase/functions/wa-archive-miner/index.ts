import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import Anthropic from 'npm:@anthropic-ai/sdk@0.120.0';

// wa-archive-miner — a segunda metade da importação do histórico.
//
// A etapa 6 importava e parava. `wa_archive_messages` enchia, mensagem por
// mensagem, e `wa_archive_findings` -- a tabela onde o aprendizado deveria
// morar -- ficava vazia, porque nada escrevia nela. Este worker é esse nada.
//
// O QUE ELE PROCURA, E POR QUE ESSA LISTA. Quando eu li o briefing do salão,
// extraí PROIBIÇÕES -- não faça duas químicas no mesmo dia, não prometa tom --
// e parei ali. A SEQUÊNCIA ficou de fora: o que vem antes, quanto tempo
// depois, o que combina com o quê. Faltando a ordem, o modelo inventa a ordem,
// e foi o que aconteceu quando ele disse "progressiva primeiro" para quem
// queria luzes. Por isso `SEQUENCIA` é o primeiro tipo desta lista e o que a
// instrução manda caçar com mais atenção.
//
// TODO ACHADO NASCE COM O TRECHO LITERAL. Sem a frase original, um padrão
// extraído é palpite sem endereço: ninguém consegue conferir se a leitura foi
// honesta, e o dono não tem como discordar de um resumo que ele não reconhece.
// `wa_mine_write` recusa a linha que vier sem trecho.
//
// E NADA DISSO VIRA REGRA SOZINHO. O que sai daqui é material de leitura, não
// política do salão: o dono confirma o que vale antes de virar regra que o
// agente obedece na frente de uma cliente.

const MODELO = 'claude-sonnet-5';
const ESFORCO = 'low' as const;

// Uma conversa por vez, e no máximo 600 falas dela. Conversa de dois anos com
// cliente fixa passa disso, e o que interessa está no começo -- é onde ela
// pergunta e ele explica. Depois vira "tenho quinta às 9h, pode ser?".
const FALAS_POR_ARQUIVO = 600;

const TIPOS = [
  'SEQUENCIA',
  'PERGUNTA_DA_CLIENTE',
  'RESPOSTA_DO_DONO',
  'OBJECAO',
  'QUEBRA_DE_OBJECAO',
  'EXPLICACAO_TECNICA',
  'CONDUCAO_PARA_AGENDA',
  'PRECO_CITADO',
  'REGRA_IMPLICITA',
  'TOM_DE_VOZ',
] as const;

const INSTRUCAO = `Você está lendo uma conversa real de WhatsApp entre o dono de um salão de beleza e uma cliente. Seu trabalho é extrair o que esse profissional SABE e que não está escrito em lugar nenhum do sistema.

O QUE MAIS IMPORTA, E É O QUE COSTUMA PASSAR BATIDO: sequência. Toda vez que ele disser ou deixar claro o que vem ANTES, o que vem DEPOIS, quanto tempo entre um e outro, o que combina com o quê, ou o que não pode junto — isso é um achado do tipo SEQUENCIA, e é o mais valioso que existe aqui. "Faz as luzes primeiro e a progressiva na semana que vem" é exatamente o tipo de frase que você está caçando.

Os outros tipos:
- PERGUNTA_DA_CLIENTE: o que ela quer saber, com as palavras dela.
- RESPOSTA_DO_DONO: como ele responde, em especial preço e prazo.
- OBJECAO: o que faz ela hesitar (preço, medo de estragar o cabelo, tempo).
- QUEBRA_DE_OBJECAO: o que ele diz que desfaz a hesitação.
- EXPLICACAO_TECNICA: o que ele explica sobre cabelo, química, cor.
- CONDUCAO_PARA_AGENDA: como ele leva da conversa para o horário marcado.
- PRECO_CITADO: valor dito, com o serviço ao lado.
- REGRA_IMPLICITA: regra do salão que aparece sem nunca ter sido anunciada.
- TOM_DE_VOZ: jeito de falar que se repete e identifica ele.

REGRAS DE HONESTIDADE, e elas valem mais que a quantidade:
1. Todo achado carrega o TRECHO LITERAL de onde saiu, copiado da conversa, sem reescrever. Achado sem trecho é recusado pelo sistema.
2. Você NÃO inventa e NÃO completa. Se ele não disse o intervalo, o achado diz o que ele disse e para aí.
3. Você NÃO generaliza uma vez só como se fosse regra. Uma frase dita uma vez tem confiança baixa, e você registra isso.
4. Preço, minuto e prazo você copia como aparecem. Não arredonda, não converte.
5. Conversa que só tem "oi", "tem horário?" e "marcado" não tem achado nenhum. Devolver lista vazia é a resposta certa, e é melhor que encher de obviedade.

Não extraia dado pessoal da cliente: nome, telefone, endereço, o que ela contou da vida dela. O que interessa é o ofício do salão, não quem é ela.`;

type Arquivo = {
  archive_id: string;
  tenant_id: string;
  contact_label: string | null;
  mensagens: number;
};

type Fala = { quem: string; texto: string; quando: string | null };

type Achado = {
  kind: string;
  titulo: string;
  conteudo: string;
  trecho: string;
  ocorrencias?: number;
  confianca?: number;
};

const FERRAMENTA: Anthropic.Tool = {
  name: 'anotar_achados',
  description:
    'Registra o que esta conversa ensina sobre o ofício deste salão. Lista vazia é resposta legítima quando a conversa não ensina nada.',
  input_schema: {
    type: 'object',
    properties: {
      achados: {
        type: 'array',
        items: {
          type: 'object',
          properties: {
            kind: { type: 'string', enum: [...TIPOS] },
            titulo: { type: 'string', description: 'Uma linha curta que resume o achado.' },
            conteudo: {
              type: 'string',
              description:
                'O que isso ensina, escrito para outra pessoa do salão entender. Português direto.',
            },
            trecho: {
              type: 'string',
              description:
                'A frase LITERAL da conversa de onde o achado saiu, copiada sem reescrever.',
            },
            ocorrencias: {
              type: 'integer',
              description: 'Quantas vezes isso aparece nesta conversa. Um, se aparece uma vez.',
            },
            confianca: {
              type: 'number',
              description:
                'De 0 a 1. Baixa quando apareceu uma vez só ou quando você está interpretando.',
            },
          },
          required: ['kind', 'titulo', 'conteudo', 'trecho', 'ocorrencias', 'confianca'],
          additionalProperties: false,
        },
      },
    },
    required: ['achados'],
    additionalProperties: false,
  },
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}

async function rpc(url: string, key: string, fn: string, args: unknown): Promise<unknown> {
  const r = await fetch(`${url}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'content-type': 'application/json' },
    body: JSON.stringify(args),
  });
  if (!r.ok) throw new Error(`RPC ${fn}: ${r.status} ${(await r.text()).slice(0, 300)}`);
  return await r.json();
}

async function autorizado(req: Request, url: string, key: string): Promise<boolean> {
  const token = req.headers.get('x-worker-token');
  if (!token) return false;
  try {
    return (await rpc(url, key, 'verify_worker_token', { p_token: token })) === true;
  } catch {
    return false;
  }
}

/** A conversa em texto, uma fala por linha, do jeito que se lê no aparelho. */
function conversaEmTexto(falas: Fala[]): string {
  return falas
    .map((f) => {
      const quem = f.quem === 'DONO' ? 'SALÃO' : 'CLIENTE';
      return `${quem}: ${String(f.texto ?? '').trim()}`;
    })
    .filter((linha) => linha.length > 8)
    .join('\n');
}

Deno.serve(async (req: Request) => {
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const anthropicKey = Deno.env.get('ANTHROPIC_API_KEY');

  if (!supabaseUrl || !serviceKey) return json(500, { ok: false, reason: 'SUPABASE_ENV_MISSING' });
  if (!(await autorizado(req, supabaseUrl, serviceKey))) {
    return json(401, { ok: false, reason: 'WORKER_TOKEN_INVALID' });
  }
  if (!anthropicKey) return json(500, { ok: false, reason: 'ANTHROPIC_API_KEY_MISSING' });

  const corpo = (await req.json().catch(() => ({}))) as { limit?: number };
  const limite = Math.max(1, Math.min(Number(corpo.limit ?? 2), 5));

  let fila: Arquivo[];
  try {
    fila = (await rpc(supabaseUrl, serviceKey, 'wa_mine_claim', { p_limit: limite })) as Arquivo[];
  } catch (erro) {
    return json(500, { ok: false, reason: 'QUEUE_READ_FAILED', detail: String(erro) });
  }

  if (!Array.isArray(fila) || fila.length === 0) {
    return json(200, { ok: true, arquivos: 0, achados: 0 });
  }

  const anthropic = new Anthropic({ apiKey: anthropicKey });
  const resultados: unknown[] = [];
  let achadosNoTotal = 0;
  let falhas = 0;

  for (const arquivo of fila) {
    try {
      const falas = (await rpc(supabaseUrl, serviceKey, 'wa_mine_conversa', {
        p_archive_id: arquivo.archive_id,
        p_limit: FALAS_POR_ARQUIVO,
      })) as Fala[];

      const texto = conversaEmTexto(Array.isArray(falas) ? falas : []);

      // Conversa curta demais não paga a leitura: três linhas de "oi" e
      // "marcado" não ensinam ofício nenhum, e cada chamada custa dinheiro.
      if (texto.length < 400) {
        await rpc(supabaseUrl, serviceKey, 'wa_mine_finish', {
          p_archive_id: arquivo.archive_id,
          p_error: null,
        });
        resultados.push({ archiveId: arquivo.archive_id, achados: 0, motivo: 'CONVERSA_CURTA' });
        continue;
      }

      const resposta = await anthropic.messages.create({
        model: MODELO,
        max_tokens: 4000,
        thinking: { type: 'adaptive' },
        output_config: { effort: ESFORCO },
        // A instrução é igual para todo arquivo de todo salão, então ela é o
        // prefixo que o cache segura. O que muda é a conversa, que vai depois.
        system: [
          {
            type: 'text',
            text: INSTRUCAO,
            cache_control: { type: 'ephemeral', ttl: '1h' },
          },
        ],
        tools: [FERRAMENTA],
        tool_choice: { type: 'tool', name: 'anotar_achados' },
        messages: [{ role: 'user', content: 'A conversa, na ordem:\n\n' + texto }],
      });

      const chamada = resposta.content.find(
        (b): b is Anthropic.ToolUseBlock => b.type === 'tool_use'
      );
      if (!chamada) throw new Error('modelo não chamou anotar_achados');

      const achados = ((chamada.input as { achados?: Achado[] })?.achados ?? []).filter(
        (a) => a && typeof a.trecho === 'string' && a.trecho.trim().length > 0
      );

      const gravacao = (await rpc(supabaseUrl, serviceKey, 'wa_mine_write', {
        p_archive_id: arquivo.archive_id,
        p_findings: achados,
      })) as { gravados?: number; recusados?: number };

      await rpc(supabaseUrl, serviceKey, 'wa_mine_finish', {
        p_archive_id: arquivo.archive_id,
        p_error: null,
      });

      achadosNoTotal += gravacao?.gravados ?? 0;
      resultados.push({
        archiveId: arquivo.archive_id,
        falas: Array.isArray(falas) ? falas.length : 0,
        gravados: gravacao?.gravados ?? 0,
        recusados: gravacao?.recusados ?? 0,
      });
    } catch (erro) {
      falhas += 1;
      console.error(
        JSON.stringify({
          event: 'mineracao_falhou',
          archiveId: arquivo.archive_id,
          detalhe: String(erro).slice(0, 300),
        })
      );
      try {
        await rpc(supabaseUrl, serviceKey, 'wa_mine_finish', {
          p_archive_id: arquivo.archive_id,
          p_error: String(erro).slice(0, 400),
        });
      } catch {
        // O erro do erro não pode derrubar o lote: o próximo arquivo segue.
      }
    }
  }

  return json(200, {
    ok: true,
    arquivos: fila.length,
    achados: achadosNoTotal,
    falhas,
    resultados,
  });
});
