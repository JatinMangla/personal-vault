'use client';

/**
 * Sign in.
 *
 * Authentication is Supabase Auth — hand-rolling auth is the single highest-risk
 * thing this project could attempt, so it delegates.
 *
 * SIGN-IN ONLY, BY DESIGN. This is a single-owner vault. It used to offer
 * "Create a new vault", which let anyone who found the URL make an account, and
 * with it a per-user storage quota carved out of the one 1 GB free tier the
 * owner depends on, plus read access to the VM metrics. Sign-ups are also
 * disabled in Supabase Auth itself; removing the button is the second half.
 *
 * Vault setup (salt, data key, recovery code) happens on the main page, which
 * handles any signed-in account that has no key material yet.
 */

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';

export default function LoginPage() {
  const router = useRouter();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleSignIn = async (event: React.FormEvent) => {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const { data, error: signInError } = await browserClient().auth.signInWithPassword({
        email,
        password,
      });
      if (signInError) throw signInError;
      if (!data.user) throw new Error('Sign in returned no account.');
      router.push('/');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Sign in failed');
    } finally {
      setBusy(false);
      setPassword('');
    }
  };

  return (
    <>
      <h1>Sign in</h1>

      <form onSubmit={handleSignIn} className="stack w-full-form">
        <div>
          <label htmlFor="email">Email</label>
          <input
            id="email"
            type="email"
            autoComplete="email"
            inputMode="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            required
          />
        </div>

        <div>
          <label htmlFor="password">Account password</label>
          <input
            id="password"
            type="password"
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            required
          />
        </div>

        <button type="submit" className="btn-primary" disabled={busy}>
          {busy ? 'Working…' : 'Sign in'}
        </button>

        {error && (
          <div className="banner banner-red" role="alert">
            {error}
          </div>
        )}
      </form>
    </>
  );
}
