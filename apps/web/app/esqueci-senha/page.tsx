'use client';

import Link from 'next/link';
import { useState, type FormEvent } from 'react';
import { createSupabaseBrowserClient } from '../../lib/supabase/browser';
import '../login/login.css';

export default function EsqueciSenhaPage() {
  const [email, setEmail] = useState('');
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState(false);
  const [error, setError] = useState('');

  async function submit(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError('');
    try {
      const supabase = createSupabaseBrowserClient();
      const { error: resetError } = await supabase.auth.resetPasswordForEmail(email, {
        redirectTo: `${window.location.origin}/auth/callback?next=/redefinir-senha`,
      });
      if (resetError) throw resetError;
      setSent(true);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Não foi possível enviar o e-mail.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="login-shell">
      <form className="login-card" onSubmit={submit}>
        <span className="login-eyebrow">Configurador do seu negócio</span>
        <h1>Esqueceu a senha?</h1>
        <p>Digite o e-mail do seu cadastro e enviamos um link para você criar uma senha nova.</p>

        {sent ? (
          <p className="login-sent">
            Enviamos um e-mail para <strong>{email}</strong>. Abra o e-mail (o mais recente) e
            clique no link para criar sua nova senha.
          </p>
        ) : (
          <>
            <label>
              E-mail
              <input
                type="email"
                required
                autoFocus
                value={email}
                onChange={(event) => setEmail(event.target.value)}
                placeholder="voce@seuemail.com"
              />
            </label>
            <button type="submit" disabled={busy || !email}>
              {busy ? 'Enviando…' : 'Enviar link de redefinição'}
            </button>
          </>
        )}

        {error && (
          <p className="login-error" role="alert">
            {error}
          </p>
        )}

        <div className="login-links">
          <Link href="/login">Voltar para entrar</Link>
          <Link href="/cadastro">Cadastrar</Link>
        </div>
      </form>
    </main>
  );
}
