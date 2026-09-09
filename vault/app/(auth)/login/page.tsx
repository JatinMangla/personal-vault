'use client';

/**
 * Sign in and first-time vault setup.
 *
 * Authentication is Supabase Auth — hand-rolling auth is the single highest-risk
 * thing this project could attempt, so it delegates.
 *
 * Setup generates the KDF salt and the recovery code. The recovery code is shown
 * EXACTLY ONCE and never stored server-side in a usable form: what the server
 * keeps is the file key wrapped under it, which is inert without the code.
 */

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { browserClient } from '@/lib/supabase-browser';
import {
  deriveExtractableKey,
  generateRecoveryCode,
  generateSalt,
  bytesToBase64,
  wrapKeyWithRecoveryCode,
  PBKDF2_ITERATIONS,
} from '@/lib/crypto';
import { createVerifier } from '@/components/VaultKeyProvider';

type Mode = 'signin' | 'signup';

export default function LoginPage() {
  const router = useRouter();
  const [mode, setMode] = useState<Mode>('signin');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [passphrase, setPassphrase] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [recoveryCode, setRecoveryCode] = useState<string | null>(null);
  const [pendingSetup, setPendingSetup] = useState(false);

  /**
   * Create the key material for an account that has none.
   *
   * Needed because an account can exist without a vault: with email
   * confirmation enabled, signUp() returns no session, so the RLS-protected
   * insert cannot run at that moment. Without this path such an account is
   * permanently unusable - it can sign in but never unlock.
   */
  const provisionVault = async (
    supabase: ReturnType<typeof browserClient>,
    userId: string,
  ): Promise<string | null> => {
    const { data: existing } = await supabase
      .from('user_keys')
      .select('user_id')
      .eq('user_id', userId)
      .maybeSingle();

    // Already provisioned. Never overwrite - that would orphan every file
    // encrypted under the previous salt.
    if (existing) return null;

    if (!passphrase || passphrase.length < 12) {
      // Reveal the passphrase field before raising, or the user is told to
      // enter something the form gives them no way to enter.
      setPendingSetup(true);
      throw new Error(
        'This account has no vault yet. Enter your encryption passphrase below (12+ characters) to finish setting it up.',
      );
    }

    const salt = generateSalt();
    const code = generateRecoveryCode();
    const extractable = await deriveExtractableKey(passphrase, salt);

    const [wrapped, verifier] = await Promise.all([
      wrapKeyWithRecoveryCode(extractable, code, salt),
      createVerifier(extractable),
    ]);

    const { error: keyError } = await supabase.from('user_keys').insert({
      user_id: userId,
      kdf_salt: bytesToBase64(salt),
      kdf_iterations: PBKDF2_ITERATIONS,
      recovery_wrapped_key: wrapped,
      passphrase_verifier: verifier,
    });
    if (keyError) throw keyError;

    return code;
  };

  const handleSignIn = async (event: React.FormEvent) => {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const supabase = browserClient();
      const { data, error: signInError } = await supabase.auth.signInWithPassword({
        email,
        password,
      });
      if (signInError) throw signInError;

      const user = data.user;
      if (!user) throw new Error('Sign in returned no account.');

      // Finish setup if this account never got its key material.
      const code = await provisionVault(supabase, user.id);
      if (code) {
        setRecoveryCode(code);
        return;
      }

      router.push('/');
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Sign in failed');
    } finally {
      setBusy(false);
      setPassword('');
    }
  };

  const handleSignUp = async (event: React.FormEvent) => {
    event.preventDefault();
    setBusy(true);
    setError(null);

    try {
      const supabase = browserClient();
      const { data, error: signUpError } = await supabase.auth.signUp({ email, password });
      if (signUpError) throw signUpError;

      const user = data.user;
      if (!user) throw new Error('Sign up did not return an account. Try again.');

      // With email confirmation enabled, signUp() returns a user but NO session,
      // so the RLS-protected insert below would fail. Detect that and tell the
      // user plainly rather than leaving a half-created account: previously this
      // path threw before writing any key material, so the account existed with
      // no vault attached and no way to finish setting it up.
      if (!data.session) {
        setPendingSetup(true);
        throw new Error(
          'Account created. Confirm your email, then sign in here to finish setting up your vault.',
        );
      }

      // Derive an extractable key ONLY so it can be wrapped under the recovery
      // code. The key used for day-to-day encryption is derived separately and
      // is non-extractable.
      const salt = generateSalt();
      const saltB64 = bytesToBase64(salt);
      const code = generateRecoveryCode();

      const extractable = await deriveExtractableKey(passphrase, salt);
      const [wrapped, verifier] = await Promise.all([
        wrapKeyWithRecoveryCode(extractable, code, salt),
        createVerifier(extractable),
      ]);

      const { error: keyError } = await supabase.from('user_keys').insert({
        user_id: user.id,
        kdf_salt: saltB64,
        kdf_iterations: PBKDF2_ITERATIONS,
        recovery_wrapped_key: wrapped,
        passphrase_verifier: verifier,
      });
      if (keyError) throw keyError;

      // Shown once. There is no second chance to display this.
      setRecoveryCode(code);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Sign up failed');
    } finally {
      setBusy(false);
      setPassword('');
      setPassphrase('');
    }
  };

  if (recoveryCode) {
    return (
      <>
        <h1>Save your recovery code</h1>
        <div className="banner banner-red">
          <strong>This is shown once and cannot be recovered later.</strong>
        </div>
        <p>Write it down and store it somewhere safe, away from this device.</p>
        <p
          className="mono card recovery-code">
          {recoveryCode}
        </p>
        <div className="banner banner-amber">
          If you lose <strong>both</strong> your passphrase and this recovery code, your
          files cannot be decrypted by anyone — including us. That is how end-to-end
          encryption is supposed to work, and it is why this warning is here rather than
          buried in a help page.
        </div>
        <button type="button" className="btn-primary" onClick={() => router.push('/')}>
          I have saved it
        </button>
      </>
    );
  }

  const isSignUp = mode === 'signup';

  return (
    <>
      <h1>{isSignUp ? 'Create your vault' : 'Sign in'}</h1>

      <form onSubmit={isSignUp ? handleSignUp : handleSignIn} className="stack w-full-form">
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
            autoComplete={isSignUp ? 'new-password' : 'current-password'}
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            required
          />
        </div>

        {(isSignUp || pendingSetup) && (
          <div>
            <label htmlFor="passphrase">Encryption passphrase</label>
            <input
              id="passphrase"
              type="password"
              autoComplete="new-password"
              value={passphrase}
              onChange={(e) => setPassphrase(e.target.value)}
              required
              minLength={12}
            />
            <p className="faint">
              Separate from your account password, and never sent to the server. It
              encrypts your files in this browser.
              {pendingSetup && !isSignUp
                ? ' Your account exists but has no vault yet — signing in with this will finish setting it up.'
                : ''}
            </p>
          </div>
        )}

        <button type="submit" className="btn-primary" disabled={busy}>
          {busy ? 'Working…' : isSignUp ? 'Create vault' : 'Sign in'}
        </button>

        {error && (
          <div className="banner banner-red" role="alert">
            {error}
          </div>
        )}

        <button
          type="button"
          onClick={() => {
            setMode(isSignUp ? 'signin' : 'signup');
            setError(null);
          }}
        >
          {isSignUp ? 'I already have an account' : 'Create a new vault'}
        </button>
      </form>
    </>
  );
}
