import 'reflect-metadata';

import { Injectable, Module, type OnModuleInit } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';

@Injectable()
class WorkerLifecycle implements OnModuleInit {
  onModuleInit(): void {
    // Queue consumers are added in later FV-01 checkpoints.
  }
}

@Module({ providers: [WorkerLifecycle] })
class WorkerModule {}

async function bootstrap(): Promise<void> {
  await NestFactory.createApplicationContext(WorkerModule, { logger: ['error', 'warn', 'log'] });
}

void bootstrap();
