// O HORARIO QUE ELA VIU.
//
// 30/09, DEV: "corte feminino ... tem horario sabado de manha?" e, tres
// mensagens depois, "Isso" -- confirmando o SERVICO. O agente consultou,
// escolheu sabado 9h sozinho e marcou. Ela nunca leu "9h" em lugar nenhum.
//
// Reservar so vale para um horario que apareceu na conversa -- oferecido por
// nos ou pedido por ela -- antes deste turno.

import type { Fala } from './antes-do-horario.ts';

function horaEMinuto(ms: number): { h: number; m: number } {
  const [h = 0, m = 0] = new Date(ms)
    .toLocaleTimeString('pt-BR', {
      timeZone: 'America/Sao_Paulo',
      hour: '2-digit',
      minute: '2-digit',
      hour12: false,
    })
    .split(':')
    .map(Number);
  return { h, m };
}

export function horarioApareceuNaConversa(conversa: Fala[], startMs: number): boolean {
  const { h, m } = horaEMinuto(startMs);
  const mm = String(m).padStart(2, '0');
  const hora = `0?${h}`;
  const padroes: RegExp[] =
    m === 0
      ? [
          // 9h, 9 horas, 9h00 -- mas nao 9h30 nem 19h.
          new RegExp(`(^|[^\\d])${hora}\\s*(h|hs|horas?)(?!\\s*[1-5]\\d)`, 'i'),
          new RegExp(`(^|[^\\d])${hora}\\s*:\\s*00(?!\\d)`, 'i'),
          new RegExp(`(^|\\s)(as|às|das|pras|para as)\\s+${hora}(?![\\d:h])`, 'i'),
        ]
      : [new RegExp(`(^|[^\\d])${hora}\\s*[:h]\\s*${mm}(?!\\d)`, 'i')];
  if (h === 12 && m === 0) padroes.push(/meio[\s-]?dia/i);
  // "depois das 15h", "a partir das 9", "antes das 12h", "entre 14h e 16h":
  // faixa, nao escolha. 30/09: "dia 10 depois das 15h" + "Re, ja falei" virou
  // 15h marcado.
  const semFaixas = (t: string) =>
    t.replace(
      /\b(depois|a\s+partir|ap[óo]s|antes|at[ée]|entre)\s+(d?[ao]s?\s+|de\s+)?\d{1,2}\s*(h|hs|horas?|:\d{2})?\s*\d{0,2}(\s*e\s*\d{1,2}\s*(h|hs|horas?|:\d{2})?\s*\d{0,2})?/gi,
      ' '
    );
  return conversa.some((f) => padroes.some((p) => p.test(semFaixas(String(f.text ?? '')))));
}
