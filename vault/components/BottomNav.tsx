'use client';

/**
 * Bottom tab bar on phones (thumb reach), horizontal bar from 768px up.
 *
 * The switch is driven entirely by CSS width in globals.css — never a device
 * sniff — so iPad Split View and Stage Manager resizing work without any JS.
 */

import Link from 'next/link';
import { usePathname } from 'next/navigation';

const TABS = [
  { href: '/', label: 'Files', icon: '📄' },
  { href: '/status', label: 'Status', icon: '📊' },
] as const;

export function BottomNav() {
  const pathname = usePathname();

  return (
    <nav className="bottom-nav" aria-label="Primary">
      {TABS.map((tab) => {
        const active = pathname === tab.href;
        return (
          <Link
            key={tab.href}
            href={tab.href}
            aria-current={active ? 'page' : undefined}
          >
            <span aria-hidden="true">{tab.icon}</span>
            <span>{tab.label}</span>
          </Link>
        );
      })}
    </nav>
  );
}
