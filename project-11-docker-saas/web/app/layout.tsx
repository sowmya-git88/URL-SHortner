import "./globals.css";
import type { ReactNode } from "react";

export const metadata = {
  title: "TaskBox SaaS · Project 11",
  description: "Next.js + NestJS + Postgres + Redis + MinIO on Docker Compose",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
