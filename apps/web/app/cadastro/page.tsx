'use client';

import Link from 'next/link';
import { useState, type FormEvent } from 'react';
import {
  formatCpf,
  formatPhone,
  formatPostalCode,
  isLikelyEmail,
  isValidCpf,
  isValidPassword,
  isValidPhone,
  isValidPostalCode,
} from '../../lib/validation';
import PasswordField from '../components/PasswordField';
import './cadastro.css';

type FormState = {
  fullName: string;
  birthDate: string;
  phone: string;
  cpf: string;
  email: string;
  password: string;
  passwordConfirm: string;
  addressStreet: string;
  addressNeighborhood: string;
  addressPostalCode: string;
  establishmentName: string;
};

const EMPTY: FormState = {
  fullName: '',
  birthDate: '',
  phone: '',
  cpf: '',
  email: '',
  password: '',
  passwordConfirm: '',
  addressStreet: '',
  addressNeighborhood: '',
  addressPostalCode: '',
  establishmentName: '',
};

export default function CadastroPage() {
  const [form, setForm] = useState<FormState>(EMPTY);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [done, setDone] = useState(false);

  function set<K extends keyof FormState>(key: K, value: FormState[K]) {
    setForm((current) => ({ ...current, [key]: value }));
  }

  function validate(): string | null {
    if (form.fullName.trim().length < 2) return 'Digite seu nome completo.';
    if (!form.birthDate) return 'Digite sua data de nascimento.';
    if (!isValidPhone(form.phone)) return 'Telefone inválido, inclua o DDD, ex.: (16) 99999-8888.';
    if (!isValidCpf(form.cpf)) return 'CPF inválido, confira os números digitados.';
    if (!isLikelyEmail(form.email)) return 'E-mail inválido.';
    if (!isValidPassword(form.password)) return 'A senha precisa ter ao menos 8 caracteres.';
    if (form.password !== form.passwordConfirm) return 'As senhas digitadas são diferentes.';
    if (form.addressStreet.trim().length < 3) return 'Digite a rua do seu endereço.';
    if (form.addressNeighborhood.trim().length < 2) return 'Digite o bairro.';
    if (!isValidPostalCode(form.addressPostalCode)) return 'CEP inválido, precisa ter 8 números.';
    if (form.establishmentName.trim().length < 2) return 'Digite o nome do seu estabelecimento.';
    return null;
  }

  async function submit(event: FormEvent) {
    event.preventDefault();
    const problem = validate();
    if (problem) {
      setError(problem);
      return;
    }
    setBusy(true);
    setError('');
    try {
      const response = await fetch('/api/auth/signup', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(form),
      });
      const result = (await response.json()) as { error?: string };
      if (!response.ok) {
        setError(result.error ?? 'Não foi possível concluir o cadastro.');
        return;
      }
      setDone(true);
    } catch {
      setError('Não foi possível concluir o cadastro. Tente novamente.');
    } finally {
      setBusy(false);
    }
  }

  if (done) {
    return (
      <main className="cadastro-shell">
        <div className="cadastro-card cadastro-narrow">
          <span className="cadastro-eyebrow">Configurador do seu negócio</span>
          <h1>Quase lá</h1>
          <p>
            Enviamos um e-mail de confirmação para <strong>{form.email}</strong>. Abra o e-mail e
            clique no link para confirmar. Depois disso você já pode entrar com seu e-mail (ou
            CPF) e a senha que você criou.
          </p>
          <Link className="cadastro-back" href="/login">
            Ir para a tela de entrar
          </Link>
        </div>
      </main>
    );
  }

  return (
    <main className="cadastro-shell">
      <form className="cadastro-card" onSubmit={submit}>
        <span className="cadastro-eyebrow">Configurador do seu negócio</span>
        <h1>Criar minha conta</h1>
        <p className="cadastro-hint">
          Este cadastro é para você, dona ou dono do salão/studio, usar o configurador. Seus
          clientes finais não precisam se cadastrar em lugar nenhum. Eles continuam marcando
          horário pelo WhatsApp.
        </p>

        <div className="cadastro-section">
          <h2>Seus dados</h2>
          <label>
            Nome completo
            <input
              type="text"
              required
              value={form.fullName}
              onChange={(event) => set('fullName', event.target.value)}
              placeholder="Ex.: Eduarda de Fiume"
            />
          </label>
          <div className="cadastro-grid two">
            <label>
              Data de nascimento
              <input
                type="date"
                required
                value={form.birthDate}
                onChange={(event) => set('birthDate', event.target.value)}
              />
            </label>
            <label>
              Telefone (com DDD)
              <input
                type="text"
                required
                inputMode="numeric"
                value={form.phone}
                onChange={(event) => set('phone', formatPhone(event.target.value))}
                placeholder="(16) 99999-8888"
              />
            </label>
          </div>
          <div className="cadastro-grid two">
            <label>
              CPF
              <input
                type="text"
                required
                inputMode="numeric"
                value={form.cpf}
                onChange={(event) => set('cpf', formatCpf(event.target.value))}
                placeholder="111.444.777-35"
              />
            </label>
            <label>
              E-mail
              <input
                type="email"
                required
                value={form.email}
                onChange={(event) => set('email', event.target.value)}
                placeholder="voce@seuemail.com"
              />
            </label>
          </div>
        </div>

        <div className="cadastro-section">
          <h2>Endereço</h2>
          <div className="cadastro-grid two">
            <label>
              Rua
              <input
                type="text"
                required
                value={form.addressStreet}
                onChange={(event) => set('addressStreet', event.target.value)}
                placeholder="Ex.: Rua das Flores, 123"
              />
            </label>
            <label>
              Bairro
              <input
                type="text"
                required
                value={form.addressNeighborhood}
                onChange={(event) => set('addressNeighborhood', event.target.value)}
                placeholder="Ex.: Centro"
              />
            </label>
          </div>
          <label>
            CEP
            <input
              type="text"
              required
              inputMode="numeric"
              value={form.addressPostalCode}
              onChange={(event) => set('addressPostalCode', formatPostalCode(event.target.value))}
              placeholder="14020-260"
            />
          </label>
        </div>

        <div className="cadastro-section">
          <h2>Seu estabelecimento</h2>
          <label>
            Nome do estabelecimento
            <input
              type="text"
              required
              value={form.establishmentName}
              onChange={(event) => set('establishmentName', event.target.value)}
              placeholder="Ex.: Salão da Maria"
            />
          </label>
          <p className="cadastro-hint small">
            Você poderá completar horário de funcionamento, equipe e serviços depois de entrar,
            no próprio configurador.
          </p>
        </div>

        <div className="cadastro-section">
          <h2>Senha de acesso</h2>
          <div className="cadastro-grid two">
            <PasswordField
              label="Senha"
              required
              value={form.password}
              onChange={(value) => set('password', value)}
              placeholder="Mínimo 8 caracteres"
            />
            <PasswordField
              label="Confirmar senha"
              required
              value={form.passwordConfirm}
              onChange={(value) => set('passwordConfirm', value)}
              placeholder="Digite a senha de novo"
            />
          </div>
        </div>

        <button type="submit" disabled={busy}>
          {busy ? 'Cadastrando…' : 'Criar minha conta'}
        </button>

        {error && (
          <p className="cadastro-error" role="alert">
            {error}
          </p>
        )}

        <p className="cadastro-footer">
          Já tem conta? <Link href="/login">Entrar</Link>
        </p>
      </form>
    </main>
  );
}
