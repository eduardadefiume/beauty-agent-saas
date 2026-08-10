// Validações puras usadas no cadastro/login de proprietárias. Sem I/O —
// testável isoladamente e reutilizável no cliente (feedback imediato) e no
// servidor (validação de verdade, que é a que importa).

export function onlyDigits(value: string): string {
  return value.replace(/\D/g, '');
}

/** Valida CPF pelos dígitos verificadores reais, não só o formato. */
export function isValidCpf(value: string): boolean {
  const digits = onlyDigits(value);
  if (digits.length !== 11) return false;
  if (/^(\d)\1{10}$/.test(digits)) return false;

  const checkDigit = (base: string, factor: number): number => {
    let total = 0;
    for (let index = 0; index < base.length; index += 1) {
      total += Number(base[index]) * (factor - index);
    }
    const remainder = (total * 10) % 11;
    return remainder === 10 ? 0 : remainder;
  };

  const base = digits.slice(0, 9);
  const firstCheck = checkDigit(base, 10);
  const secondCheck = checkDigit(base + String(firstCheck), 11);
  return digits === base + String(firstCheck) + String(secondCheck);
}

export function isValidPostalCode(value: string): boolean {
  return /^\d{8}$/.test(onlyDigits(value));
}

export function isValidPhone(value: string): boolean {
  const digits = onlyDigits(value);
  return digits.length === 10 || digits.length === 11;
}

export function isValidPassword(value: string): boolean {
  return value.length >= 8;
}

export function isLikelyEmail(value: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value.trim());
}

export function formatCpf(value: string): string {
  const digits = onlyDigits(value).slice(0, 11);
  return digits
    .replace(/(\d{3})(\d)/, '$1.$2')
    .replace(/(\d{3})(\d)/, '$1.$2')
    .replace(/(\d{3})(\d{1,2})$/, '$1-$2');
}

export function formatPostalCode(value: string): string {
  const digits = onlyDigits(value).slice(0, 8);
  return digits.replace(/(\d{5})(\d)/, '$1-$2');
}

export function formatPhone(value: string): string {
  const digits = onlyDigits(value).slice(0, 11);
  if (digits.length <= 10) {
    return digits.replace(/(\d{2})(\d{4})(\d{0,4})/, '($1) $2-$3').trim().replace(/-$/, '');
  }
  return digits.replace(/(\d{2})(\d{5})(\d{0,4})/, '($1) $2-$3').trim().replace(/-$/, '');
}
