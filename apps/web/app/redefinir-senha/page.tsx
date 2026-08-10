'use client';

import Link from 'next/link';
import { useEffect, useState, type FormEvent } from 'react';
import { createSupabaseBrowserClient } from '../../lib/supabase/browser';
import { isValidPassword } from '../../lib/validation';
import '../login/login.css';

export default function RedefinirSenhaPage() {
  const [checking, setChecking] = useState(true);
  const [hasSession, setHasSession] = useState(false);
  const [password, setPassword] = useState('');
  const [passwordConfirm, setPasswordConfirm] = useState('');
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    const supabase = createSupabaseBrowserClient();
    void supabase.auth.getSession().then(({ data }) => {
      setHasSession(Boolean(data.session));
      setChecking(false);
    });
  }, []);

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (!isValidPassword(password)) {
      setError('A senha precisa ter ao menos 8 caracteres.');
      return;
    }
    if (password !== passwordConfirm) {
      setError('As senhas digitadas são diferentes.');
      return;
    }
    setBusy(true);
    setError('');
    try {
      const supabase = createSupabaseBrowserClient();
      const { error: updateError } = await supabase.auth.updateUser({ password });
      if (updateError) throw updateError;
      setDone(true);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Não foi possível trocar a senha.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="login-shell">
      <div className="login-card">
        <span className="login-eyebrow">Configurador do seu negócio</span>
        <h1>Nova senha</h1>

        {checking ? (
          <p>Verificando o link…</p>
        ) : done ? (
          <>
            <p className="login-sent">Senha alterada. Agora é só entrar com ela.</p>
            <Link className="login-links" href="/login">
              Ir para a tela de entrar
            </Link>
          </>
        ) : !hasSession ? (
          <>
            <p className="login-error" role="alert">
              Este link não é mais válido. Peça um novo link de redefinição.
            </p>
            <Link href="/esqueci-senha">Pedir novo link</Link>
          </>
        ) : (
          <form onSubmit={submit}>
            <label>
              Nova senha
              <input
                type="password"
                required
                autoFocus
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                placeholder="Mínimo 8 caracteres"
              />
            </label>
            <label>
              Confirmar nova senha
              <input
                type="password"
                required
                value={passwordConfirm}
                onChange={(event) => setPasswordConfirm(event.target.value)}
                placeholder="Digite a senha de novo"
              />
            </label>
            <button type="submit" disabled={busy}>
              {busy ? 'Salvando…' : 'Salvar nova senha'}
            </button>
            {error && (
              <p className="login-error" role="alert">
                {error}
              </p>
            )}
          </form>
        )}
      </div>
    </main>
  );
}
