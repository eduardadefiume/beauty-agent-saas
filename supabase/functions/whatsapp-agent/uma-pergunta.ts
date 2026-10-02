// UMA PERGUNTA POR VEZ (Eddy e atendente).
//
// 02/10, DEV, William-robô: o Eddy perguntou "você tem um jeito próprio de
// explicar o teste?" e, na bolha seguinte, "fotos ou áudio sobre cor?". O
// prompt já dizia "uma pergunta por vez"; o modelo não obedeceu. Se o dono
// responde "pode ser o padrão", uma das duas some.
//
// A primeira bolha com pergunta fica inteira (pares de propósito, como "qual o
// Pix e em nome de quem?", moram na mesma bolha). Nas bolhas seguintes, só as
// frases que perguntam saem; aviso e confirmação ficam. A pergunta tirada
// volta no próximo turno pelo próprio roteiro.
//
// Na atendente, 02/10: 37 de 101 respostas tinham mais de um "?". O caso que
// importa: "essa química tinha formol?" + "tenho quarta às 9h, pode ser?" --
// ela responde "sim" e ninguém sabe a quê.

const URL = /https?:\/\/\S+/g;
// "Oi, tudo bem?" é cumprimento, não pergunta que espera resposta.
const CUMPRIMENTO =
  /\b(tudo bem|tudo bom|td bem|tdb|tudo certinho|como vai|como você está|como voce esta|tudo joia|tudo jóia)\s*\?+/gi;
const temPergunta = (t: string) => /\?/.test(t.replace(URL, '').replace(CUMPRIMENTO, ''));

export function umaPerguntaPorVez(mensagens: string[]): string[] {
  const saida: string[] = [];
  let jaPerguntou = false;
  for (const m of mensagens ?? []) {
    const texto = String(m ?? '');
    if (!jaPerguntou) {
      saida.push(texto);
      if (temPergunta(texto)) jaPerguntou = true;
      continue;
    }
    if (!temPergunta(texto)) {
      saida.push(texto);
      continue;
    }
    const frases = texto.split(/(?<=[.!?…])\s+/).filter((f) => !temPergunta(f));
    const resto = frases.join(' ').trim();
    if (resto) saida.push(resto);
  }
  return saida;
}
