import { describe, expect, it } from 'vitest';

import {
  formatCpf,
  isValidCpf,
  isValidPassword,
  isValidPhone,
  isValidPostalCode,
  onlyDigits,
} from './validation';

describe('isValidCpf', () => {
  it('aceita um CPF com dígitos verificadores corretos', () => {
    expect(isValidCpf('111.444.777-35')).toBe(true);
    expect(isValidCpf('11144477735')).toBe(true);
  });

  it('rejeita dígito verificador errado', () => {
    expect(isValidCpf('111.444.777-36')).toBe(false);
  });

  it('rejeita todos os dígitos iguais', () => {
    expect(isValidCpf('111.111.111-11')).toBe(false);
  });

  it('rejeita tamanho errado', () => {
    expect(isValidCpf('123')).toBe(false);
  });
});

describe('isValidPostalCode', () => {
  it('aceita 8 dígitos com ou sem máscara', () => {
    expect(isValidPostalCode('14020-260')).toBe(true);
    expect(isValidPostalCode('14020260')).toBe(true);
  });
  it('rejeita menos de 8 dígitos', () => {
    expect(isValidPostalCode('1402026')).toBe(false);
  });
});

describe('isValidPhone', () => {
  it('aceita 10 ou 11 dígitos', () => {
    expect(isValidPhone('(16) 3333-4444')).toBe(true);
    expect(isValidPhone('(16) 99333-4444')).toBe(true);
  });
  it('rejeita menos de 10 dígitos', () => {
    expect(isValidPhone('999999')).toBe(false);
  });
});

describe('isValidPassword', () => {
  it('exige ao menos 8 caracteres', () => {
    expect(isValidPassword('1234567')).toBe(false);
    expect(isValidPassword('12345678')).toBe(true);
  });
});

describe('formatCpf / onlyDigits', () => {
  it('formata e desformata de forma consistente', () => {
    expect(formatCpf('11144477735')).toBe('111.444.777-35');
    expect(onlyDigits('111.444.777-35')).toBe('11144477735');
  });
});
