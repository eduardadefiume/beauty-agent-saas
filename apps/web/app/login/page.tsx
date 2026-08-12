'use client';

import Link from 'next/link';
import { useState, type FormEvent } from 'react';
import { createSupabaseBrowserClient } from '../../lib/supabase/browser';
import PasswordField from '../components/PasswordField';
import './login.css';

export default function LoginPage() {
  const [identifier, setIdentifier] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const [showMagicLink, setShowMagicLink] = useState(false);
  const [magicEmail, setMagicEmail] = useState('');
  const [magicSent, setMagicSent] = useState(false);
  const [magicBusy, setMagicBusy] = useState(false);
  const [magicError, setMagicError] = useState('');

  async function login(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError('');
    try {
      const response = await fetch('/api/auth/login', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ identifier, password }),
      });
      const result = (await response.json()) as { error?: string };
      if (!response.ok) {
        setError(result.error ?? 'Não foi possível entrar.');
        return;
      }
      window.location.href = '/';
    } catch {
      setError('Não foi possível entrar. Tente novamente.');
    } finally {
      setBusy(false);
    }
  }

  async function sendMagicLink(event: FormEvent) {
    event.preventDefault();
    setMagicBusy(true);
    setMagicError('');
    try {
      const supabase = createSupabaseBrowserClient();
      const { error: signInError } = await supabase.auth.signInWithOtp({
        email: magicEmail,
        options: { emailRedirectTo: `${window.location.origin}/auth/callback` },
      });
      if (signInError) throw signInError;
      setMagicSent(true);
    } catch (caught) {
      setMagicError(caught instanceof Error ? caught.message : 'Não foi possível enviar o link.');
    } finally {
      setMagicBusy(false);
    }
  }

  return (
    <main className="login-shell">
      <form className="login-card" onSubmit={login}>
        <span className="login-eyebrow">Configurador do seu negócio</span>
        <h1>Entrar</h1>
        <p>Digite seu e-mail ou CPF e sua senha.</p>

        <label>
          E-mail ou CPF
          <input
            type="text"
            required
            autoFocus
            value={identifier}
            onChange={(event) => setIdentifier(event.target.value)}
            placeholder="Ex.: voce@seuemail.com ou 111.444.777-35"
          />
        </label>
        <PasswordField
          label="Senha"
          required
          value={password}
          onChange={setPassword}
          placeholder="Sua senha"
        />
        <button type="submit" disabled={busy || !identifier || !password}>
          {busy ? 'Entrando…' : 'Entrar'}
        </button>

        <div className="login-links">
          <Link href="/esqueci-senha">Esqueceu a senha?</Link>
          <Link href="/cadastro">Cadastrar</Link>
        </div>

        {error && (
          <p className="login-error" role="alert">
            {error}
          </p>
        )}
      </form>

      <div className="login-card login-secondary">
        <button
          type="button"
          className="linklike"
          onClick={() => setShowMagicLink((current) => !current)}
        >
          {showMagicLink ? 'Ocultar' : 'Ainda não tem senha? Entrar por link no e-mail'}
        </button>
        {showMagicLink && (
          <form onSubmit={sendMagicLink}>
            {magicSent ? (
              <p className="login-sent">
                Link enviado para <strong>{magicEmail}</strong>. Abra seu e-mail e clique no link
                mais recente.
              </p>
            ) : (
              <>
                <label>
                  E-mail
                  <input
                    type="email"
                    required
                    value={magicEmail}
                    onChange={(event) => setMagicEmail(event.target.value)}
                    placeholder="voce@seuemail.com"
                  />
                </label>
                <button type="submit" disabled={magicBusy || !magicEmail}>
                  {magicBusy ? 'Enviando…' : 'Enviar link de acesso'}
                </button>
              </>
            )}
            {magicError && (
              <p className="login-error" role="alert">
                {magicError}
              </p>
            )}
          </form>
        )}
      </div>
    </main>
  );
}
