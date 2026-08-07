'use client';

import { useState, type FormEvent } from 'react';
import { createSupabaseBrowserClient } from '../../lib/supabase/browser';
import './login.css';

export default function LoginPage() {
  const [email, setEmail] = useState('');
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState(false);
  const [error, setError] = useState('');

  async function sendLink(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError('');
    try {
      const supabase = createSupabaseBrowserClient();
      const { error: signInError } = await supabase.auth.signInWithOtp({
        email,
        options: { emailRedirectTo: `${window.location.origin}/auth/callback` },
      });
      if (signInError) throw signInError;
      setSent(true);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'Não foi possível enviar o link.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="login-shell">
      <form className="login-card" onSubmit={sendLink}>
        <span className="login-eyebrow">Configurador do seu negócio</span>
        <h1>Entrar</h1>
        <p>Digite seu e-mail e enviamos um link de acesso. Sem senha.</p>

        {sent ? (
          <p className="login-sent">
            Link enviado para <strong>{email}</strong>. Abra seu e-mail e clique no link (o mais
            recente) para entrar.
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
              {busy ? 'Enviando…' : 'Enviar link de acesso'}
            </button>
          </>
        )}

        {error && (
          <p className="login-error" role="alert">
            {error}
          </p>
        )}
      </form>
    </main>
  );
}
