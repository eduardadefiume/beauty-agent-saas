// Entender o arquivo que o WhatsApp exporta.
//
// Fica em arquivo separado do `index.ts` de propósito: sem o import do runtime
// da borda, esta lógica pode ser importada pelo teste que roda no CI. É a
// parte mais arriscada da etapa 6 -- se o parser picar a mensagem errada, o
// arquivo inteiro nasce torto e ninguém percebe olhando a tela.
//
// O FORMATO muda com a plataforma e com o idioma. Android pt-BR escreve
// `03/09/2026 14:32 - William: texto`; iOS escreve
// `[03/09/2026 14:32:11] William: texto`. Por isso são dois padrões e não um.

export type LinhaLida = {
  position: number;
  autor: string | null;
  texto: string;
  sentAt: string | null;
  midia: string | null;
  quem?: 'DONO' | 'CLIENTE' | 'SISTEMA';
};

const ANDROID =
  /^(\d{1,2})\/(\d{1,2})\/(\d{2,4}),?\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(?:-|–)\s*(.*)$/;
const IOS =
  /^\[(\d{1,2})\/(\d{1,2})\/(\d{2,4}),?\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(?:[AP]M)?\]\s*(.*)$/i;

const MIDIA =
  /([A-Za-z0-9_\-.]+\.(?:jpg|jpeg|png|webp|mp4|opus|ogg|m4a|pdf))\s*\((?:arquivo anexado|file attached)\)/i;
const MIDIA_OCULTA = /<M[íi]dia oculta>|<Media omitted>|imagem ocultada|figurinha omitida/i;

// O export não traz fuso horário. O salão é de São Paulo, então -03:00 é a
// leitura honesta: tratar como UTC deslocaria toda conversa em três horas, e
// "ela mandou às 9 da manhã" viraria meio-dia.
function paraIso(
  d: string,
  m: string,
  a: string,
  h: string,
  min: string,
  s: string | undefined
): string | null {
  const ano = a.length === 2 ? 2000 + Number(a) : Number(a);
  const dia = Number(d);
  const mes = Number(m);
  const hora = Number(h);
  const minuto = Number(min);
  if (!Number.isFinite(ano) || mes < 1 || mes > 12 || dia < 1 || dia > 31) return null;
  if (hora > 23 || minuto > 59) return null;
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${ano}-${pad(mes)}-${pad(dia)}T${pad(hora)}:${pad(minuto)}:${pad(Number(s ?? '0'))}-03:00`;
}

export function separarMensagens(bruto: string): LinhaLida[] {
  const linhas = bruto.split(/\r?\n/);
  const saida: LinhaLida[] = [];
  let atual: LinhaLida | null = null;

  for (const linha of linhas) {
    // O iOS põe caracteres invisíveis de direção de texto no começo da linha.
    const limpa = linha.replace(/[‎‏‪-‮]/g, '');
    const m = IOS.exec(limpa) ?? ANDROID.exec(limpa);

    if (!m) {
      // Linha que não começa com data é continuação da mensagem anterior. Sem
      // isto, uma explicação técnica de cinco linhas viraria cinco mensagens
      // picadas -- e é justamente essa explicação que se quer aprender.
      if (atual) atual.texto += `\n${limpa}`;
      continue;
    }

    if (atual) saida.push(atual);

    const resto = m[7] ?? '';
    const separador = resto.indexOf(': ');
    // Linha sem "Nome: " é aviso do próprio WhatsApp (criptografia, mudança de
    // número). Fica como SISTEMA em vez de virar fala de alguém.
    const autor = separador > 0 ? resto.slice(0, separador).trim() : null;
    const texto = separador > 0 ? resto.slice(separador + 2) : resto;
    const anexo = MIDIA.exec(texto);

    atual = {
      position: saida.length,
      autor,
      texto,
      sentAt: paraIso(m[1] ?? '', m[2] ?? '', m[3] ?? '', m[4] ?? '', m[5] ?? '', m[6]),
      midia: anexo ? (anexo[1] ?? null) : MIDIA_OCULTA.test(texto) ? '<oculta>' : null,
    };
  }
  if (atual) saida.push(atual);

  return saida.map((l, i) => ({ ...l, position: i }));
}

// O WhatsApp não marca "eu" e "ela": marca o NOME de quem escreveu, do jeito
// que estava salvo na agenda do dono. O dono é quem mais fala em cada arquivo.
//
// Empate deixa tudo como CLIENTE de propósito: chutar quem é o dono e errar
// contaminaria justamente a voz que se quer aprender, e é melhor um arquivo
// sem a marca do que um arquivo com a marca trocada.
export function decidirQuemEQuem(linhas: LinhaLida[], nomeDoDono: string | null): LinhaLida[] {
  const contagem = new Map<string, number>();
  for (const l of linhas) {
    if (l.autor) contagem.set(l.autor, (contagem.get(l.autor) ?? 0) + 1);
  }

  let dono = nomeDoDono;
  if (!dono) {
    const ordenado = [...contagem.entries()].sort((a, b) => b[1] - a[1]);
    const primeiro = ordenado[0];
    const segundo = ordenado[1];
    if (primeiro && segundo && primeiro[1] > segundo[1]) dono = primeiro[0];
  }

  return linhas.map((l) => ({
    ...l,
    quem: l.autor === null ? 'SISTEMA' : dono !== null && l.autor === dono ? 'DONO' : 'CLIENTE',
  }));
}
