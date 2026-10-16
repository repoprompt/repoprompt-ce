export interface UserCardProps {
  user: User;
  onSelect(id: string): void;
}

type User = {
  id: string;
  displayName: string;
};

export class UserCardModel {
  title: string;

  constructor(title: string) {
    this.title = title;
  }

  render(props: UserCardProps): string {
    return props.user.displayName;
  }
}

export function formatUser(user: User): string {
  return user.displayName;
}
