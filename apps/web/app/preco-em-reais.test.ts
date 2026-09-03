import { describe, expect, it } from 'vitest';
import { minorParaCampo, reaisParaMinor } from './configurator-real';

// O bug que este teste tranca:
//
// O campo de preço pedia CENTAVOS, e o rótulo dizia isso. A Duda digitou 120
// querendo R$ 120 e o catálogo passou a mostrar R$ 1,20 -- o campo cumpriu
// exatamente o que prometia e entregou exatamente o que ninguém queria.
//
// Não é erro de digitação dela: é o sistema exigindo que uma pessoa faça
// conversão de unidade para preencher um formulário. Num catálogo de cinquenta
// serviços, esse campo erra cinquenta vezes, e cada erro é um preço que o
// agente promete para a cliente.
//
// Guardar em centavos continua certo -- dinheiro em ponto flutuante acumula
// erro. O que este teste tranca é QUEM converte: o sistema, nunca a pessoa.

describe('preço se digita em reais', () => {
  it('cento e vinte reais viram doze mil centavos, não cento e vinte', () => {
    expect(reaisParaMinor('120')).toBe(12000);
  });

  it('aceita o jeito brasileiro de escrever, com vírgula', () => {
    expect(reaisParaMinor('120,50')).toBe(12050);
  });

  it('aceita ponto como decimal, que é o que o teclado numérico manda', () => {
    expect(reaisParaMinor('120.50')).toBe(12050);
  });

  it('ignora o R$ e o espaço que a pessoa cola junto', () => {
    expect(reaisParaMinor('R$ 120,00')).toBe(12000);
  });

  it('não arredonda para baixo escondido: 0,995 vira 100 centavos', () => {
    expect(reaisParaMinor('0,995')).toBe(100);
  });

  it('campo vazio é preço não cadastrado, e isso não é zero', () => {
    expect(reaisParaMinor('')).toBeNull();
    expect(reaisParaMinor('   ')).toBeNull();
  });

  it('texto que não é número não vira preço nenhum', () => {
    expect(reaisParaMinor('abc')).toBeNull();
    expect(reaisParaMinor('-30')).toBeNull();
  });

  it('o que está gravado volta ao campo em reais', () => {
    expect(minorParaCampo(12000)).toBe('120');
    expect(minorParaCampo(12050)).toBe('120.5');
    expect(minorParaCampo(null)).toBe('');
  });

  it('ida e volta não muda o valor', () => {
    for (const centavos of [100, 4500, 12000, 12050, 99999]) {
      expect(reaisParaMinor(minorParaCampo(centavos))).toBe(centavos);
    }
  });
});
